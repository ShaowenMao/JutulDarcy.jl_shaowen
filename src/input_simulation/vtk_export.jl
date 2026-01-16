using WriteVTK
using StaticArrays
using WriteVTK: VTKPolyhedron, VTKPointData, VTKCellData

# Robust conversion: MRST indices may come in as Float64 from MAT (e.g., 1.0, 2.0)
as_int(x) = x isa Integer ? Int(x) : Int(round(x))
to_int_vec(A) = as_int.(vec(A))

"""
    write_volume_vtu(G; cell_data=Dict(), point_data=Dict(), filename="grid_volume")

Export true 3D volumetric MRST grid as VTU using polyhedron cells.
Works when `G` is a Dict loaded from MAT (your case), with keys:
G["nodes"]["coords"], G["faces"]["nodePos"], G["faces"]["nodes"],
G["cells"]["facePos"], G["cells"]["faces"].
"""
function write_volume_vtu(G;
                          cell_data = Dict{String,AbstractVector}(),
                          point_data = Dict{String,AbstractVector}(),
                          filename::AbstractString = "grid_volume")

    # --- Access MRST grid data (Dict-style) ---
    nodes = G["nodes"]
    faces = G["faces"]
    cells = G["cells"]

    coords    = nodes["coords"]                    # Nnodes × 3
    nodePos   = to_int_vec(faces["nodePos"])       # Nfaces+1
    faceNodes = to_int_vec(faces["nodes"])         # total face-node list

    facePos       = to_int_vec(cells["facePos"])   # Ncells+1
    cellFacesRaw  = cells["faces"]                 # (NcellFacesTotal×1) or (×2)

    # --- Points ---
    npts = size(coords, 1)
    vtk_points = [SVector{3,Float64}(coords[i,1], coords[i,2], coords[i,3]) for i in 1:npts]

    # --- Cells (polyhedra) ---
    ncells = length(facePos) - 1
    vtk_cells = Vector{VTKPolyhedron}(undef, ncells)

    @inbounds for c in 1:ncells
        a = facePos[c]
        b = facePos[c+1] - 1

        # face IDs for this cell (MRST sometimes stores [faceId, sign])
        fids = if ndims(cellFacesRaw) == 2 && size(cellFacesRaw, 2) >= 1
            to_int_vec(cellFacesRaw[a:b, 1])
        else
            to_int_vec(cellFacesRaw[a:b])
        end

        face_tuples = Vector{Tuple}(undef, length(fids))
        all_nodes = Int[]

        for (k, f) in pairs(fids)
            ia = nodePos[f]
            ib = nodePos[f+1] - 1
            nids = faceNodes[ia:ib]     # global node ids for that face (ordered)
            append!(all_nodes, nids)
            face_tuples[k] = Tuple(nids)
        end

        conn = unique(all_nodes)  # global node ids used by this polyhedron
        vtk_cells[c] = VTKPolyhedron(conn, face_tuples...)
    end

    # --- Write VTU ---
    vtk = vtk_grid(filename, vtk_points, vtk_cells)

    # Cell-centered arrays
    for (name, v) in cell_data
        @assert length(v) == ncells "Cell array '$name' must have length ncells=$ncells"
        vtk[name, VTKCellData()] = v
    end

    # Point arrays (optional)
    for (name, v) in point_data
        @assert length(v) == npts "Point array '$name' must have length npts=$npts"
        vtk[name, VTKPointData()] = v
    end

    close(vtk)
    return nothing
end

