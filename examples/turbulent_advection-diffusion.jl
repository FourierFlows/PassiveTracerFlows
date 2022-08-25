# # Advection-diffusion of tracer by a turbulent flow
#
# This is an example demonstrating the advection-diffusion of a tracer using a 
# turbulent flow generated by the `GeophysicalFlows.jl` package.
#
# ## Install dependencies
#
# First let's make sure we have all the required packages installed

# ```julia
# using Pkg
# pkg.add(["PassiveTracerFlows", "Printf", "CairoMakie", "JLD2"])
# ```
#
# ## Let's begin
# First load packages needed to run this example.
using PassiveTracerFlows, Printf, CairoMakie, JLD2
using Random: seed!

# ## Choosing a device: CPU or GPU
dev = CPU()
nothing # hide

# ## Setting up a `MultiLayerQG.Problem` to generate a turbulent flow
#
# The tubulent flow we use to advect the passive tracer is generated using the 
# [`MultiLayerQG`](https://fourierflows.github.io/GeophysicalFlowsDocumentation/stable/modules/multilayerqg/) module
# from the [`GeophysicalFlows.jl`](https://fourierflows.github.io/GeophysicalFlowsDocumentation/stable/) package.
# A more detailed setup of this two layer system is found at the
# [GeophysicalFlows Documentation](https://fourierflows.github.io/GeophysicalFlowsDocumentation/stable/literated/multilayerqg_2layer/).
#
# ### Numerical and time stepping parameters for the flow

      n = 128            # 2D resolution = n²
stepper = "FilteredRK4"  # timestepper
     dt = 2.5e-3         # timestep
nothing # hide

# ### Physical parameters 
L = 2π                   # domain size
μ = 5e-2                 # bottom drag
β = 5                    # the y-gradient of planetary PV

nlayers = 2              # number of layers
f₀, g = 1, 1             # Coriolis parameter and gravitational constant
 H = [0.2, 0.8]          # the rest depths of each layer
 ρ = [4.0, 5.0]          # the density of each layer

 U = zeros(nlayers) # the imposed mean zonal flow in each layer
 U[1] = 1.0
 U[2] = 0.0
nothing # hide

# ### `MultiLayerQG.Problem` setup, shortcuts and initial conditions
MQGprob = MultiLayerQG.Problem(nlayers, dev;
                               nx=n, Lx=L, f₀, g, H, ρ, U, μ, β,
                               dt, stepper, aliased_fraction=0)
grid = MQGprob.grid
x, y = grid.x, grid.y

# Initial conditions                        
seed!(1234) # reset of the random number generator for reproducibility
q₀  = 1e-2 * ArrayType(dev)(randn((grid.nx, grid.ny, nlayers)))
q₀h = MQGprob.timestepper.filter .* rfft(q₀, (1, 2)) # apply rfft  only in dims=1, 2
q₀  = irfft(q₀h, grid.nx, (1, 2))                    # apply irfft only in dims=1, 2

MultiLayerQG.set_q!(MQGprob, q₀)
nothing # hide

# ## Tracer advection-diffusion setup
#
# Now that we have a `MultiLayerQG.Problem` setup to generate our turbulent flow, we
# setup an advection-diffusion simulation. This is done by passing the `MultiLayerQG.Problem`
# as an argument to `TracerAdvectionDiffusion.Problem` which sets up an advection-diffusion problem
# with same parameters where applicable. We also need to pass a value for the constant diffusivity `κ`,
# the `stepper` used to step the problem forward and when we want the tracer released into the flow.
# We will let the flow run up to `t = tracer_release_time` and then release the tracer and let it
# evolve with the flow.

κ = 0.002                        # Constant diffusivity
nsteps = 4000                    # total number of time-steps
tracer_release_time = 25.0       # run flow for some time before releasing tracer

ADprob = TracerAdvectionDiffusion.Problem(dev, MQGprob; κ, stepper, tracer_release_time)

# ## Initial condition for concentration in both layers
#
# We have a two layer system so we will advect-diffuse the tracer in both layers.
# To do this we set the initial condition for tracer concetration as a Gaussian centered at the origin.
# Then we create some shortcuts for the `TracerAdvectionDiffusion.Problem`.
gaussian(x, y, σ) = exp(-(x^2 + y^2) / (2σ^2))

amplitude, spread = 10, 0.15
c₀ = [amplitude * gaussian(x[i], y[j], spread) for j=1:grid.ny, i=1:grid.nx]

TracerAdvectionDiffusion.set_c!(ADprob, c₀)

# Shortcuts for advection-diffusion problem
sol, clock, vars, params, grid = ADprob.sol, ADprob.clock, ADprob.vars, ADprob.params, ADprob.grid
x, y = grid.x, grid.y

# ## Saving output
#
# The parent package `FourierFlows.jl` provides the functionality to save the output from our simulation.
# To do this we write a function `get_concentration` and pass this to the `Output` function along 
# with the `TracerAdvectionDiffusion.Problem` and the name of the output file.

function get_concentration(prob)
  invtransform!(prob.vars.c, deepcopy(prob.sol), prob.params.MQGprob.params)

  return prob.vars.c
end

function get_streamfunction(prob)
  params, vars, grid = prob.params.MQGprob.params, prob.params.MQGprob.vars, prob.grid

  @. vars.qh = prob.params.MQGprob.sol

  streamfunctionfrompv!(vars.ψh, vars.qh, params, grid)

  invtransform!(vars.ψ, vars.ψh, params)

  return vars.ψ
end

output = Output(ADprob, "advection-diffusion.jld2",
                (:concentration, get_concentration), (:streamfunction, get_streamfunction))

# This saves information that we will use for plotting later on
saveproblem(output)

# ## Step the problem forward and save the output
#
# We specify that we would like to save the concentration every `save_frequency` timesteps;
# then we step the problem forward.

save_frequency = 50 # frequency at which output is saved

startwalltime = time()
while clock.step <= nsteps
  if clock.step % save_frequency == 0
    saveoutput(output)
    log = @sprintf("Output saved, step: %04d, t: %.2f, walltime: %.2f min",
                   clock.step, clock.t, (time()-startwalltime) / 60)

    println(log)
  end

  stepforward!(ADprob)
  stepforward!(params.MQGprob)
  MultiLayerQG.updatevars!(params.MQGprob)
end

# ## Visualizing the output
#
# We now have output from our simulation saved in `advection-diffusion.jld2`.
# As a demonstration, we load the JLD2 output and create a time series for the tracer
# that has been advected-diffused in the lower layer of our fluid.

# Create time series for the concentration and streamfunction in the bottom layer, `layer = 2`.
file = jldopen(output.path)

iterations = parse.(Int, keys(file["snapshots/t"]))
t = [file["snapshots/t/$i"] for i ∈ iterations]

layer = 2

c = [file["snapshots/concentration/$i"][:, :, layer] for i ∈ iterations]
ψ = [file["snapshots/streamfunction/$i"][:, :, layer] for i ∈ iterations]
nothing # hide

# We normalize all streamfunctions to have maximum absolute value `amplitude / 5`.
for i in 1:lastindex(ψ)
  ψ[i] *= (amplitude / 5) / maximum(abs, ψ[i])
end

x,  y  = file["grid/x"],  file["grid/y"]
Lx, Ly = file["grid/Lx"], file["grid/Ly"]

n = Observable(1)

c_anim = @lift c[$n]
ψ_anim = @lift ψ[$n]
title = @lift @sprintf("concentration, t = %s", t[$n])

fig = Figure(resolution = (700, 700))
ax = Axis(fig[1, 1], 
            xlabel = "x",
            ylabel = "y",
            aspect = 1,
            title = title, 
            limits = ((-Lx/2, Lx/2), (-Ly/2, Ly/2)))

hm = heatmap!(ax, x, y, c_anim; colormap = :balance, colorrange = (-amplitude/5, amplitude/5))
contour!(ax, x, y, ψ_anim; levels = 0.15:0.3:1.5, color = :grey, linestyle = :solid, alpha = 0.5)
contour!(ax, x, y, ψ_anim; levels = -0.15:-0.3:-1.5, color = :grey, linestyle = :dash, alpha = 0.5)

nothing # hide

# Create a movie of the tracer with the streamlines.

frames = 1:length(t)
record(fig, "turbulentflow_advection-diffusion.mp4", frames, framerate = 18) do i
    n[] = i
end

nothing # hide
# ![](turbulentflow_advection-diffusion.mp4)
