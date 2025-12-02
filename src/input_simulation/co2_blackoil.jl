# using Revise  # Good to keep this at the very top
# using JutulDarcy
# using Jutul
# using GLMakie
# using MAT

# path = raw"C:/Users/Shaow/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case.mat"

# # Control flags
# run_sim   = false
# plot_flag = true   # set to false to skip all plotting

# # ---------------------------------------------------------
# # 0. Run simulation (optional)
# # ---------------------------------------------------------
# if run_sim
#     simulate_mrst_case(path, write_mrst = true)
# end

# if !plot_flag
#     println("Plotting disabled. Skipping plots.")
# else
#     println("Plotting enabled. Generating plots...")

#     # Read all exported data
#     exported = MAT.matread(path)

#     # Get Jutul grid/domain by reusing JutulDarcy helper
#     data_domain, mrst_data = JutulDarcy.reservoir_domain_from_mrst(path; extraout = true, convert_grid = false)
#     G_raw = mrst_data["G"]
#     g = JutulDarcy.MRSTWrapMesh(G_raw)

#     # Small helper for consistent 3D axes
#     function axis3!(fig; title = "")
#         ax = Axis3(fig[1, 1];
#             title  = title,
#             aspect = :data,
#             xlabel = "X", ylabel = "Y", zlabel = "Z",
#         )
#         ax.zreversed[] = true
#         ax.azimuth[]   = 270
#         ax.elevation[] = 0
#         return ax
#     end

#     # ---------------------------------------------------------
#     # 1. Computational grid
#     # ---------------------------------------------------------
#     fig_mesh = Figure(size = (800, 600))
#     ax3 = axis3!(fig_mesh; title = "3D mesh")
#     Jutul.plot_mesh_edges!(ax3, g; color = :black)
#     display(fig_mesh)
#     save("mesh.png", fig_mesh)

#     # ---------------------------------------------------------
#     # 2. Permeability distribution (log10(k [mD]))
#     # ---------------------------------------------------------
#     perm_raw = copy(exported["rock"]["perm"])
#     kx = perm_raw isa AbstractMatrix ? perm_raw[:, 1] : perm_raw
#     perm_mD  = kx ./ 9.869233e-16
#     perm_log = log10.(perm_mD .+ 1e-6)

#     fig_perm = Figure(size = (800, 600))
#     axp = axis3!(fig_perm; title = "Permeability Distribution (log₁₀ k [mD])")


#     @infiltrate

#     plt_perm = Jutul.plot_cell_data!(axp, g, perm_log; colormap = :copper)
#     Colorbar(fig_perm[1, 2], plt_perm, label = "log₁₀(k [mD])")
#     display(fig_perm)
#     save("perm_logk.png", fig_perm)

#     # ---------------------------------------------------------
#     # 3. Saturation region indices
#     # ---------------------------------------------------------
#     reg = vec(copy(exported["rock"]["regions"]["saturation"]))

#     fig_reg = Figure(size = (800, 600))
#     axr = axis3!(fig_reg; title = "Saturation Regions")
#     plt_reg = Jutul.plot_cell_data!(axr, g, reg; colormap = :copper)
#     Colorbar(fig_reg[1, 2], plt_reg, label = "Region index")
#     display(fig_reg)
#     save("regions.png", fig_reg)

#     # ---------------------------------------------------------
#     # 4. Porosity distribution
#     # ---------------------------------------------------------
#     poro = vec(copy(exported["rock"]["poro"]))

#     fig_poro = Figure(size = (800, 600))
#     axpo = axis3!(fig_poro; title = "Porosity Distribution")
#     plt_poro = Jutul.plot_cell_data!(axpo, g, poro;
#         colormap   = :copper,
#         colorrange = (0.1, 0.3),
#     )
#     Colorbar(fig_poro[1, 2], plt_poro, label = "Porosity")
#     display(fig_poro)
#     save("porosity.png", fig_poro)
# end

using Revise  # Good to keep this at the very top
using JutulDarcy
using Jutul
using GLMakie
using MAT
using WriteVTK
using StaticArrays
include("vtk_export.jl")

path = raw"C:/Users/Shaow/OneDrive/MIT/mrst-2025a/SINTEF-AppliedCompSci-MRST-75749fa/core/output/jutul/lluis_field_case.mat"

# Control flags
run_sim   = true   # set to true to rerun simulation
plot_flag = false   # set to false to skip all plotting
vtu_flag  = true    # set to false to skip writing .vtu for ParaView

# ---------------------------------------------------------
# 0. Run simulation (optional)
# ---------------------------------------------------------
if run_sim
    simulate_mrst_case(path, write_mrst = true)
end

# ---------------------------------------------------------
# 1. Read exported data and construct mesh
# ---------------------------------------------------------
exported = MAT.matread(path)

data_domain, mrst_data = JutulDarcy.reservoir_domain_from_mrst(
    path; extraout = true, convert_grid = false
)
G_raw = mrst_data["G"]
g = JutulDarcy.MRSTWrapMesh(G_raw)

# Precompute cell-wise rock properties once
perm_raw = copy(exported["rock"]["perm"])
kx       = perm_raw isa AbstractMatrix ? perm_raw[:, 1] : perm_raw
perm_mD  = kx ./ 9.869233e-16
perm_log = log10.(perm_mD .+ 1e-6)

reg  = vec(copy(exported["rock"]["regions"]["saturation"]))
poro = vec(copy(exported["rock"]["poro"]))

# ---------------------------------------------------------
# 2. Plotting (Makie)
# ---------------------------------------------------------
if plot_flag
    println("Plotting enabled. Generating plots...")

    # Small helper for consistent 3D axes
    function axis3!(fig; title = "")
        ax = Axis3(fig[1, 1];
            title  = title,
            aspect = :data,
            xlabel = "X", ylabel = "Y", zlabel = "Z",
        )
        ax.zreversed[] = true
        ax.azimuth[]   = 270
        ax.elevation[] = 0
        return ax
    end

    # 2.1 Computational grid
    fig_mesh = Figure(size = (800, 600))
    ax3 = axis3!(fig_mesh; title = "3D mesh")
    Jutul.plot_mesh_edges!(ax3, g; color = :black)
    display(fig_mesh)
    save("mesh.png", fig_mesh)

    # 2.2 Permeability distribution (log10(k [mD]))
    fig_perm = Figure(size = (800, 600))
    axp = axis3!(fig_perm; title = "Permeability Distribution (log₁₀ k [mD])")
    plt_perm = Jutul.plot_cell_data!(axp, g, perm_log; colormap = :copper)
    Colorbar(fig_perm[1, 2], plt_perm, label = "log₁₀(k [mD])")
    display(fig_perm)
    save("perm_logk.png", fig_perm)

    # 2.3 Saturation region indices
    fig_reg = Figure(size = (800, 600))
    axr = axis3!(fig_reg; title = "Saturation Regions")
    plt_reg = Jutul.plot_cell_data!(axr, g, reg; colormap = :copper)
    Colorbar(fig_reg[1, 2], plt_reg, label = "Region index")
    display(fig_reg)
    save("regions.png", fig_reg)

    # 2.4 Porosity distribution
    fig_poro = Figure(size = (800, 600))
    axpo = axis3!(fig_poro; title = "Porosity Distribution")
    plt_poro = Jutul.plot_cell_data!(axpo, g, poro;
        colormap   = :copper,
        colorrange = (0.1, 0.3),
    )
    Colorbar(fig_poro[1, 2], plt_poro, label = "Porosity")
    display(fig_poro)
    save("porosity.png", fig_poro)
else
    println("Plotting disabled. Skipping plots.")
end

# ---------------------------------------------------------
# 3. Export VTU files for ParaView
# ---------------------------------------------------------
# ---------------------------------------------------------
# 3. Export triangulated surface + properties to ParaView (.vtu)
# ---------------------------------------------------------
if vtu_flag
    cell_data = Dict{String,AbstractVector}(
        "perm_log10_mD" => perm_log,
        "region"        => reg,
        "porosity"      => poro,
    )
    write_surface_vtu(g, cell_data; filename = "lluis_field_case_surface")
    println("VTU export complete: lluis_field_case_surface.vtu")
else
    println("VTU export disabled. Skipping .vtu file generation.")
end
