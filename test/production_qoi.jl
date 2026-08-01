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
    gas_mobility = JutulDarcy.ProductionQoIGasMobilityAccounting(
        :drainage,
        [0.1, 0.3],
        [0.1, 0.3],
        [1.0, 1.0],
        [1.0, 1.0],
        NaN,
        NaN,
        0.0,
        1.0e-10
    )
    return JutulDarcy.ProductionQoIContext(
        "required",
        "",
        "",
        "",
        "synthetic",
        "synthetic_manifest_sha256",
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
        gas_mobility,
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

@testset "Killough local trapped-saturation endpoint" begin
    drainage = PhaseRelativePermeability(
        [0.0, 0.05, 1.0],
        [0.0, 0.0, 1.0]
    )
    imbibition = PhaseRelativePermeability(
        [0.0, 0.4, 1.0],
        [0.0, 0.0, 1.0]
    )
    model = JutulDarcy.KilloughHysteresis(tol = 0.1, s_min = 0.05)
    historical_maximum = 0.6
    critical = JutulDarcy.killough_scanning_critical_saturation(
        model,
        drainage,
        imbibition,
        historical_maximum
    )
    expected_k = 1.0/(0.4 - 0.05) - 1.0/(1.0 - 0.05)
    expected_m = 1.0 + 0.1*(1.0 - historical_maximum)
    expected = 0.05 + (historical_maximum - 0.05)/(
        expected_m + expected_k*(historical_maximum - 0.05)
    )
    @test critical ≈ expected
    @test JutulDarcy.hysteresis_impl(
        model,
        drainage,
        imbibition,
        critical,
        historical_maximum
    ) ≈ 0.0 atol = 1.0e-14
    @test JutulDarcy.hysteresis_impl(
        model,
        drainage,
        imbibition,
        critical + 1.0e-3,
        historical_maximum
    ) > 0.0

    relperm = JutulDarcy.ReservoirRelativePermeabilities(
        g = (drainage, imbibition),
        og = (drainage, imbibition),
        regions = [1, 1],
        hysteresis_g = model
    )
    accounting = JutulDarcy.production_qoi_gas_mobility_accounting(
        Dict(:RelativePermeabilities => relperm),
        Dict(:MaxSaturations => zeros(2, 2)),
        2
    )
    @test accounting.mode == :killough
    @test accounting.drainage_critical == [0.05, 0.05]
    @test accounting.imbibition_critical == [0.4, 0.4]
    @test accounting.drainage_s_max == [1.0, 1.0]
    @test accounting.imbibition_s_max == [1.0, 1.0]

    invalid_imbibition = PhaseRelativePermeability(
        [0.0, 0.02, 1.0],
        [0.0, 0.0, 1.0]
    )
    invalid_relperm = JutulDarcy.ReservoirRelativePermeabilities(
        g = (drainage, invalid_imbibition),
        og = (drainage, invalid_imbibition),
        regions = [1, 1],
        hysteresis_g = model
    )
    @test_throws ErrorException begin
        JutulDarcy.production_qoi_gas_mobility_accounting(
            Dict(:RelativePermeabilities => invalid_relperm),
            Dict(:MaxSaturations => zeros(2, 2)),
            2
        )
    end
end

@testset "GoM QoI history-dependent mass partition" begin
    context = two_cell_qoi_context()
    context.gas_mobility = JutulDarcy.ProductionQoIGasMobilityAccounting(
        :killough,
        [0.05, 0.3],
        [0.4, 0.6],
        [1.0, 1.0],
        [1.0, 1.0],
        0.1,
        0.05,
        0.0,
        1.0e-10
    )
    state = Dict{Symbol, Any}(
        :FluidVolume => [10.0, 20.0],
        :Pressure => [110.0, 180.0],
        :Saturations => [0.8 0.5; 0.2 0.5],
        :MaxSaturations => [0.8 0.5; 0.6 0.5],
        :PhaseMassDensities => [1000.0 1000.0; 100.0 200.0],
        :Rs => [0.1, 0.2],
        :ShrinkageFactors => [1.0 1.1; 0.5 0.8],
        :TotalMasses => [0.0 0.0; 360.0 2550.0]
    )
    inventory = JutulDarcy.production_qoi_atomic_inventory(context, state)
    @test inventory.mobile ≈ [0.0, 800.0]
    @test inventory.drainage_critical_immobile ≈ [0.0, 1200.0]
    @test inventory.residual_trapped ≈ [200.0, 0.0]
    @test inventory.hysteresis_incremental_trapped ≈ [150.0, 0.0]
    @test inventory.immobile ≈ [200.0, 1200.0]
    @test inventory.free ≈ [200.0, 2000.0]
    @test inventory.dissolved ≈ [160.0, 550.0]
    @test inventory.total ≈ [360.0, 2550.0]
    @test inventory.scanning_count == [1, 0]
    @test inventory.hysteresis_active_count == [1, 0]
    @test inventory.residual_trapped_count == [1, 0]
    @test inventory.hysteresis_incremental_trapped_count == [1, 0]
    @test inventory.residual_trapped_gas_pore_volume ≈ [2.0, 0.0]
    @test inventory.hysteresis_incremental_trapped_gas_pore_volume ≈
        [1.5, 0.0]

    drainage_history = deepcopy(state)
    drainage_history[:MaxSaturations][2, 1] = 0.2
    drainage_inventory = JutulDarcy.production_qoi_atomic_inventory(
        context,
        drainage_history
    )
    @test drainage_inventory.mobile ≈ [150.0, 800.0]
    @test drainage_inventory.drainage_critical_immobile ≈ [50.0, 1200.0]
    @test drainage_inventory.residual_trapped == [0.0, 0.0]
    @test drainage_inventory.hysteresis_incremental_trapped == [0.0, 0.0]

    imbibition_state = deepcopy(state)
    imbibition_state[:Saturations][:, 1] = [0.7, 0.3]
    imbibition_state[:MaxSaturations][:, 1] = [0.8, 1.0]
    imbibition_state[:TotalMasses][2, 1] = 440.0
    imbibition_inventory = JutulDarcy.production_qoi_atomic_inventory(
        context,
        imbibition_state
    )
    @test imbibition_inventory.mobile ≈ [0.0, 800.0]
    @test imbibition_inventory.drainage_critical_immobile ≈ [0.0, 1200.0]
    @test imbibition_inventory.residual_trapped ≈ [300.0, 0.0]
    @test imbibition_inventory.hysteresis_incremental_trapped ≈ [250.0, 0.0]
    @test imbibition_inventory.imbibition_count == [1, 0]

    below_s_min = JutulDarcy.production_qoi_active_gas_mobility(
        context.gas_mobility,
        1,
        0.04,
        0.6
    )
    @test below_s_min.branch == :drainage_below_killough_s_min
    @test below_s_min.critical == 0.05
    full_imbibition = JutulDarcy.production_qoi_active_gas_mobility(
        context.gas_mobility,
        1,
        0.2,
        1.0
    )
    @test full_imbibition.branch == :imbibition
    @test full_imbibition.critical == 0.4
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
    @test inventory.drainage_critical_immobile ≈ [100.0, 1200.0]
    @test inventory.residual_trapped == [0.0, 0.0]
    @test inventory.hysteresis_incremental_trapped == [0.0, 0.0]
    @test inventory.mobile ≈ [100.0, 800.0]
    @test inventory.free ≈ [200.0, 2000.0]
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
    @test by_id["domain_all"][:free_co2_mass_kg] ≈ 2200.0
    @test by_id["domain_all"][:residual_trapped_co2_mass_kg] == 0.0
    @test by_id["domain_all"][:hysteresis_incremental_trapped_co2_mass_kg] ==
        0.0
    @test by_id["domain_all"][:free_co2_centroid_x_m] ≈ 10.0/11.0
    @test by_id["domain_all"][:free_co2_spread_x_m] ≈ sqrt(10.0)/11.0
    @test by_id["domain_all"][:gas_saturation_pv_weighted_mean] ≈ 0.4
    @test by_id["domain_all"][:pressure_change_pv_weighted_mean_pa] ≈ -10.0
    @test by_id["domain_all"][:pressure_change_pv_weighted_rms_pa] ≈ sqrt(300.0)
    @test by_id["domain_all"][:pore_volume_sg_ge_1e_4_m3] ≈ 30.0
    diagnostic_row = Dict(
        string(key) => string(value)
        for (key, value) in by_id["domain_all"]
    )
    @test isnothing(JutulDarcy.production_qoi_validate_region_diagnostics(
        diagnostic_row,
        "synthetic domain",
        :drainage
    ))
    invalid_partition = copy(diagnostic_row)
    invalid_partition["hysteresis_incremental_trapped_co2_mass_kg"] = "1.0"
    @test_throws ErrorException begin
        JutulDarcy.production_qoi_validate_partition_row(
            invalid_partition,
            "synthetic domain"
        )
    end
    invalid_diagnostics = copy(diagnostic_row)
    invalid_diagnostics["hysteresis_active_cell_count"] = "1"
    @test_throws ErrorException begin
        JutulDarcy.production_qoi_validate_region_diagnostics(
            invalid_diagnostics,
            "synthetic domain",
            :drainage
        )
    end

    invalid_saturation = deepcopy(state)
    invalid_saturation[:Saturations][1, 1] = 0.7
    @test_throws ErrorException JutulDarcy.production_qoi_atomic_inventory(
        context,
        invalid_saturation
    )
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
        domain = only(filter(
            row -> row[:region_id] == "domain_all",
            region_rows
        ))
        for (regional_field, global_field) in (
                (:free_co2_mass_kg, :domain_free_co2_mass_kg),
                (:mobile_free_co2_mass_kg, :domain_mobile_free_co2_mass_kg),
                (
                    :immobile_free_co2_mass_kg,
                    :domain_immobile_free_co2_mass_kg
                ),
                (
                    :drainage_critical_immobile_free_co2_mass_kg,
                    :domain_drainage_critical_immobile_free_co2_mass_kg
                ),
                (
                    :residual_trapped_co2_mass_kg,
                    :domain_residual_trapped_co2_mass_kg
                ),
                (
                    :hysteresis_incremental_trapped_co2_mass_kg,
                    :domain_hysteresis_incremental_trapped_co2_mass_kg
                ),
                (:dissolved_co2_mass_kg, :domain_dissolved_co2_mass_kg),
                (:total_co2_mass_kg, :domain_total_co2_mass_kg)
            )
            global_row[global_field] = domain[regional_field]
        end
        global_row[:case_key] = context.case_key
        global_row[:campaign_manifest_sha256] =
            context.campaign_manifest_sha256
        global_row[:injector_name] = ""
        global_row[:flux_method] =
            JutulDarcy.PRODUCTION_QOI_FLUX_METHOD
        global_row[:mobility_partition_method] =
            JutulDarcy.PRODUCTION_QOI_MOBILITY_METHOD

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
        summary_header, summary_rows = JutulDarcy.production_qoi_parse_table(
            joinpath(root, "leakage_case_summary.tsv")
        )
        @test summary_header ==
            string.(JutulDarcy.PRODUCTION_QOI_CASE_SUMMARY_COLUMNS)
        @test length(summary_rows) == 1
        @test all(value -> !isempty(value), values(only(summary_rows)))
    end
end
