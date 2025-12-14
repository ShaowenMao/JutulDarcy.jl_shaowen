using WriteVTK
using StaticArrays
using WriteVTK: MeshCell
using WriteVTK.VTKCellTypes: VTK_TRIANGLE

"""
    write_surface_vtu(mesh::MRSTWrapMesh, cell_data; filename = "mesh_surface")

Export a triangulated surface of the MRST mesh as a VTK unstructured grid (.vtu)
for ParaView.

- Uses `triangulate_mesh(mesh; outer = false)` (all relevant faces).
- Attaches cell-wise properties as point data, mapped via `mapper.Cells`.
"""
function write_surface_vtu(mesh::MRSTWrapMesh,
                           cell_data::Dict{String,AbstractVector};
                           filename::AbstractString = "mesh_surface")

    prim = triangulate_mesh(mesh; outer = false)
    pts  = prim.points          # Npoints × 3
    tri  = prim.triangulation   # Ntris × 3
    mapper = prim.mapper        # has .Cells, .Faces, .indices

    npts, nd = size(pts)
    @assert nd == 3 "Expected points as N×3 (x,y,z). Got size $(size(pts))."

    vtk_points = Vector{SVector{3,Float64}}(undef, npts)
    @inbounds for i in 1:npts
        vtk_points[i] = SVector(pts[i,1], pts[i,2], pts[i,3])
    end

    ntri, tri_ncols = size(tri)
    @assert tri_ncols == 3 "Triangulation should be N×3 triangles."

    cells = Vector{MeshCell}(undef, ntri)
    @inbounds for i in 1:ntri
        cells[i] = MeshCell(VTK_TRIANGLE, vec(tri[i, :]))
    end

    vtk = vtk_grid(filename, vtk_points, cells)

    # Map cell-wise arrays to per-vertex values via mapper.Cells
    for (name, vec) in cell_data
        mapped = mapper.Cells(vec)
        @assert length(mapped) == npts "Mapped length for $name does not match npts"
        vtk[name] = mapped
    end

    close(vtk)  # writes filename.vtu
    return nothing
end