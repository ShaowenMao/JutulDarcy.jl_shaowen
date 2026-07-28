using Test
using JutulDarcy

function synthetic_gom_qoi_metadata()
    primary = Int[]
    push!(primary, 1)
    strat_cells = Int[]
    side = Int[]
    unit = Int[]
    facies = Int[]
    for unit_id in 1:21
        for side_id in 1:2
            push!(primary, unit_id + 1)
            push!(strat_cells, length(primary))
            push!(side, side_id)
            push!(unit, unit_id)
            push!(facies, isodd(unit_id) ? 1 : 2)
        end
    end
    append!(primary, 23:33)
    push!(primary, 58)
    nc = length(primary)
    return Dict{String, Any}(
        "qoi_semantics" => Dict{String, Any}(
            "schema" => "gom_qoi_semantics_v1",
            "primary_unit_id" => UInt8.(primary),
            "cell_count" => UInt64(nc)
        ),
        "qoi_stratigraphy" => Dict{String, Any}(
            "cells" => Int32.(strat_cells),
            "side_id" => Int16.(side),
            "stratigraphic_unit_id" => Int16.(unit),
            "facies_id" => Int16.(facies)
        )
    )
end

function two_cell_qoi_context()
    atomic_regions = [
        JutulDarcy.ProductionQoIRegion(
            "r1", "Region 1", "atomic", UInt8[1], "1", "",
            "Synthetic region 1."
        ),
        JutulDarcy.ProductionQoIRegion(
            "r2", "Region 2", "atomic", UInt8[2], "2", "",
            "Synthetic region 2."
        )
    ]
    regions = vcat(
        atomic_regions,
        JutulDarcy.ProductionQoIRegion(
            "domain_all", "Domain", "aggregate", UInt8[1, 2], "1,2", "",
            "Synthetic domain."
        )
    )
    return JutulDarcy.ProductionQoIContext(
        "required",
        "",
        "",
        "",
        "synthetic",
        "",
        UInt8[1, 2],
        atomic_regions,
        regions,
        Dict(region.id => index for (index, region) in enumerate(regions)),
        JutulDarcy.ProductionQoIInterface[],
        Int32[],
        Int32[],
        [100.0, 200.0],
        [10.0, 20.0],
        [0.0 1.0; 0.0 0.0; 100.0 200.0],
        [0.1, 0.3],
        [0.0, 0.0],
        0.0,
        "",
        "",
        "",
        ""
    )
end

@testset "GoM QoI semantic compiler" begin
    metadata = synthetic_gom_qoi_metadata()
    compiled = JutulDarcy.production_qoi_compile_regions(metadata)
    @test length(compiled.atomic_regions) == 55
    @test length(compiled.atomic_code) == 55
    @test sort(unique(compiled.atomic_code)) == UInt8.(1:55)
    @test all(count(==(code), compiled.atomic_code) == 1 for code in UInt8.(1:55))
    @test haskey(compiled.region_index, "storage_lm2")
    @test haskey(compiled.region_index, "fault_all")
    @test haskey(compiled.region_index, "top_seal_system")
    @test count(
        region -> region.role == "atomic",
        compiled.regions
    ) == 55

    bad = deepcopy(metadata)
    bad["qoi_semantics"]["primary_unit_id"][1] = UInt8(23)
    @test_throws ErrorException JutulDarcy.production_qoi_compile_regions(bad)
end

@testset "GoM QoI mass partition" begin
    context = two_cell_qoi_context()
    state = Dict{Symbol, Any}(
        :FluidVolume => [10.0, 20.0],
        :Pressure => [110.0, 180.0],
        :Saturations => [0.8 0.5; 0.2 0.5],
        :PhaseMassDensities => [1000.0 1000.0; 100.0 200.0],
        :Rs => [0.1, 0.2],
        :ShrinkageFactors => [1.0 1.1; 0.5 0.8],
        :CapillaryPressure => reshape([5.0, 8.0], 1, :),
        :TotalMasses => [0.0 0.0; 360.0 2550.0]
    )
    inventory =
        JutulDarcy.production_qoi_atomic_inventory(context, state)
    @test inventory.immobile ≈ [100.0, 1200.0]
    @test inventory.mobile ≈ [100.0, 800.0]
    @test inventory.dissolved ≈ [160.0, 550.0]
    @test inventory.total ≈ [360.0, 2550.0]
    @test sum(inventory.total) ≈
        JutulDarcy.production_qoi_domain_total_mass(state)

    rows = JutulDarcy.production_qoi_region_rows(
        context,
        inventory,
        1,
        1.0
    )
    by_id = Dict(row[:region_id] => row for row in rows)
    @test by_id["domain_all"][:total_co2_mass_kg] ≈ 2910.0
    @test (
        by_id["r1"][:total_co2_mass_kg] +
        by_id["r2"][:total_co2_mass_kg]
    ) ≈ by_id["domain_all"][:total_co2_mass_kg]
    @test by_id["r1"][:pressure_change_max_pa] == 10.0
    @test by_id["r2"][:pressure_change_max_pa] == -20.0
end

@testset "GoM QoI oriented interface rates" begin
    interface = JutulDarcy.ProductionQoIInterface(
        "a_to_b",
        "A to B",
        "a",
        "b",
        "synthetic",
        Int32[1, 2],
        Int8[1, -1],
        "Synthetic orientation test."
    )
    result = JutulDarcy.production_qoi_oriented_flux_totals(
        interface,
        Int32[1, 2],
        [10.0, 4.0],
        [2.0, -1.0],
        [12.0, 3.0]
    )
    @test result == (10.0, 4.0, 3.0, 0.0, 12.0, 3.0)

    reversed = JutulDarcy.ProductionQoIInterface(
        "b_to_a",
        "B to A",
        "b",
        "a",
        "synthetic",
        interface.faces,
        .-interface.signs,
        "Reversed synthetic orientation."
    )
    reverse_result = JutulDarcy.production_qoi_oriented_flux_totals(
        reversed,
        Int32[1, 2],
        [10.0, 4.0],
        [2.0, -1.0],
        [12.0, 3.0]
    )
    @test reverse_result ==
        (result[2], result[1], result[4], result[3], result[6], result[5])
    @test reverse_result[5] - reverse_result[6] ==
        -(result[5] - result[6])
end

@testset "GoM QoI atomic bundle and consolidation" begin
    mktempdir() do root
        context = two_cell_qoi_context()
        context.summary_dir = root
        context.ready_dir = joinpath(root, "qoi", "ready")
        context.row_dir = joinpath(root, "qoi", "rows")
        mkpath(context.ready_dir)
        mkpath(context.row_dir)

        state = Dict{Symbol, Any}(
            :FluidVolume => [10.0, 20.0],
            :Pressure => [110.0, 180.0],
            :Saturations => [0.8 0.5; 0.2 0.5],
            :PhaseMassDensities => [1000.0 1000.0; 100.0 200.0],
            :Rs => [0.1, 0.2],
            :ShrinkageFactors => [1.0 1.1; 0.5 0.8],
            :TotalMasses => [0.0 0.0; 360.0 2550.0]
        )
        inventory =
            JutulDarcy.production_qoi_atomic_inventory(context, state)
        region_rows = JutulDarcy.production_qoi_region_rows(
            context,
            inventory,
            1,
            1.0
        )
        global_row = JutulDarcy.production_qoi_base_row(
            context,
            "global",
            1,
            1.0
        )
        for column in JutulDarcy.PRODUCTION_QOI_GLOBAL_COLUMNS
            haskey(global_row, column) || (global_row[column] = 0.0)
        end
        global_row[:case_key] = context.case_key
        global_row[:campaign_manifest_sha256] = ""
        global_row[:injector_name] = ""
        global_row[:flux_method] =
            JutulDarcy.PRODUCTION_QOI_FLUX_METHOD

        ready = JutulDarcy.production_qoi_ready_path(context, 1)
        JutulDarcy.production_qoi_write_table(
            ready,
            JutulDarcy.PRODUCTION_QOI_BUNDLE_COLUMNS,
            vcat(Dict{Symbol, Any}[global_row], region_rows)
        )
        @test length(
            JutulDarcy.production_qoi_validate_bundle(context, ready, 1)
        ) == 4
        JutulDarcy.production_commit_qoi_bundle!(context, 1)
        @test !isfile(ready)
        @test isfile(JutulDarcy.production_qoi_row_path(context, 1))
        @test JutulDarcy.production_qoi_row_indices(context) == [1]

        result = JutulDarcy.production_consolidate_qoi!(
            context;
            require_complete = true,
            final_schedule_step = 1
        )
        @test result.global_rows == 1
        @test result.region_rows == 3
        @test result.interface_rows == 0
        for filename in (
                "leakage_global_steps.tsv",
                "regional_co2_inventory_steps.tsv",
                "interface_flux_steps.tsv",
                "leakage_case_summary.tsv",
                "QOI_OUTPUT_COMPLETE.tsv"
            )
            @test isfile(joinpath(root, filename))
        end
    end
end
