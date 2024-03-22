using WGPUTranspiler
using WGPUTranspiler: TypeExpr, Scope, WorkGroupDims, computeBlock

# Small hack to support TypeExpr of WGPUTranspiler.
# TODO think of better abstraction.
function WGPUTranspiler.typeInfer(scope::Scope, tExpr::TypeExpr, v::Val{:WgpuArray})
	return WgpuArray{map(x -> WGPUTranspiler.typeInfer(scope, x), tExpr.types)...}
end

export @wgpukernel, getShaderCode, WGPUKernelObject, wgpuCall

function getWgpuDevice()
	get!(task_local_storage(), :WGPUDevice) do
		WGPUCore.getDefaultDevice(nothing)
	end
end

using MacroTools
using CodeTracking
using Lazy
using Infiltrator

# TODO remove
using WGPUCompute
using Infiltrator

struct WGPUKernelObject
	kernelFunc::Function
end

mutable struct KernelBuildContext
	inargs::Dict{Symbol, Any}
	tmpargs::Array{Symbol}
	typeargs::Array{Symbol}
	stmnts::Array{Expr}
	globals::Array{Expr}
	indent::Int # Helps debugging
	kernel # TODO function body with all statements will reside here
end

function getShaderCode(f, args...; workgroupSizes=(), workgroupCount=())
	fexpr = @code_string(f(args...)) |> Meta.parse |> MacroTools.striplines
	scope = Scope(Dict(), Dict(), Dict(), 0, nothing, quote end)
	@info fexpr
	cblk = computeBlock(scope, true, workgroupSizes, workgroupCount, f, args, fexpr)
	tblk = transpile(scope, cblk)
    return tblk
end

function compileShader(f, args...; workgroupSizes=(), workgroupCount=())
	shaderSrc = getShaderCode(f, args...; workgroupSizes=workgroupSizes, workgroupCount=workgroupCount)
	@info shaderSrc |> MacroTools.striplines |> MacroTools.flatten
	@info wgslCode(shaderSrc)
	cShader = nothing
	try
		cShader = createShaderObj(WGPUCompute.getWgpuDevice(), shaderSrc; savefile=true)
	catch(e)
		@info e
		rethrow(e)
	end
	@info cShader.src
	task_local_storage((f, :shader, eltype.(args), size.(args)), cShader)
	return cShader
end

function preparePipeline(f::Function, args...; workgroupSizes=(), workgroupCount=())
	gpuDevice = WGPUCompute.getWgpuDevice()
	cShader = get!(task_local_storage(), (f, :shader, eltype.(args), size.(args))) do
		compileShader(f, args...; workgroupSizes=workgroupSizes, workgroupCount=workgroupCount)
	end
	bindingLayouts = []
	bindings = []

	bindingCount = 0
	for (_, arg) in enumerate(args)
		if typeof(arg) <: WgpuArray
			bindingCount += 1
			push!(bindingLayouts, 
				WGPUCore.WGPUBufferEntry => [
					:binding => bindingCount - 1,
					:visibility => "Compute",
					:type => "Storage"
				],
			)
		end
	end

	bindingCount = 0

	for (_, arg) in enumerate(args)
		if typeof(arg) <: WgpuArray
			bindingCount += 1
			push!(bindings, 
				WGPUCore.GPUBuffer => [
					:binding => bindingCount - 1,
					:buffer => arg.storageBuffer,
					:offset => 0,
					:size => reduce(*, (arg |> size)) * sizeof(eltype(arg))
				],
			)
		end
	end

	pipelineLayout = WGPUCore.createPipelineLayout(gpuDevice, "PipeLineLayout", bindingLayouts, bindings)
	computeStage = WGPUCore.createComputeStage(cShader.internal[], f |> string)
	computePipeline = WGPUCore.createComputePipeline(gpuDevice, "computePipeline", pipelineLayout, computeStage)
	# task_local_storage((nameof(f), :bindgrouplayout, T, size(x)), bindGroupLayouts)
	task_local_storage((nameof(f), :bindings, eltype.(args), size.(args)), bindings)
	task_local_storage((nameof(f), :bindinglayouts, eltype.(args), size.(args)), bindingLayouts)
	task_local_storage((nameof(f), :layout, eltype.(args), size.(args)), pipelineLayout)
	task_local_storage((nameof(f), :pipeline, eltype.(args), size.(args)), computePipeline)
	task_local_storage((nameof(f), :bindgroup, eltype.(args), size.(args)), pipelineLayout.bindGroup)
	task_local_storage((nameof(f), :computestage, eltype.(args), size.(args)), computeStage)
end

function compute(f, args...; workgroupSizes=(), workgroupCount=())
	gpuDevice = WGPUCompute.getWgpuDevice()
	commandEncoder = WGPUCore.createCommandEncoder(gpuDevice, "Command Encoder")
	computePass = WGPUCore.beginComputePass(commandEncoder)
	WGPUCore.setPipeline(computePass, task_local_storage((nameof(f), :pipeline, eltype.(args), size.(args))))
	WGPUCore.setBindGroup(computePass, 0, task_local_storage((nameof(f), :bindgroup, eltype.(args), size.(args))), UInt32[], 0, 99999)
	WGPUCore.dispatchWorkGroups(computePass, workgroupCount...) # workgroup size needs work here
	WGPUCore.endComputePass(computePass)
	WGPUCore.submit(gpuDevice.queue, [WGPUCore.finish(commandEncoder),])
end

function kernelFunc(funcExpr)
	if 	@capture(funcExpr, function fname_(fargs__) where Targs__ fbody__ end)
		kernelfunc = quote
			function $fname(args::Tuple{WgpuArray}, workgroupSizes, workgroupCount)
				$preparePipeline($(funcExpr), args...)
				$compute($(funcExpr), args...; workgroupSizes=workgroupSizes, workgroupCount=workgroupCount)
				return nothing
			end
		end |> unblock
		return esc(quote $kernelfunc end)
	else
		error("Couldnt capture function")
	end
end

function getFunctionBlock(func, args)
	fString = CodeTracking.definition(String, which(func, args))
	return Meta.parse(fString |> first)
end

function wgpuCall(kernelObj::WGPUKernelObject, args...)
	kernelObj.kernelFunc(args...)
end

macro wgpukernel(launch, wgSize, wgCount, ex)
	code = quote end
	@gensym f_var kernel_f kernel_args kernel_tt kernel
	if @capture(ex, fname_(fargs__))
		(vars, var_exprs) = assign_args!(code, fargs)
		push!(code.args, quote
				$kernel_args = ($(var_exprs...),)
				$kernel_tt = Tuple{map(Core.Typeof, $kernel_args)...}
				kernel = function wgpuKernel(args...)
					$preparePipeline($fname, args...; workgroupSizes=$wgSize, workgroupCount=$wgCount)
					$compute($fname, args...; workgroupSizes=$wgSize, workgroupCount=$wgCount)
				end
				if $launch == true
					wgpuCall(WGPUKernelObject(kernel), $(kernel_args)...)
				else
					WGPUKernelObject(kernel)
				end
			end
		)
	end
	return esc(code)
end
