using Test
using JutulDarcy
using ForwardDiff
import Jutul

@testset "schema-4 accepted-state primal extraction" begin
    well_tag = ForwardDiff.Tag(Jutul.simulate, JutulDarcy.Wells)
    cell_tag = ForwardDiff.Tag(Jutul.simulate, Jutul.Cells)
    well_value = ForwardDiff.Dual{well_tag}(2.5, 1.0)
    cell_value = ForwardDiff.Dual{cell_tag}(3.5, 1.0, 2.0)
    @test JutulDarcy.production_qoi_primal_float(well_value) == 2.5
    @test JutulDarcy.production_qoi_primal_float(cell_value) == 3.5
    @test JutulDarcy.production_qoi_schema4_primal(well_value) == 2.5
    @test JutulDarcy.production_qoi_schema4_primal(cell_value) == 3.5
end

function schema4_spatial_fixture()
    nw = JutulDarcy.PRODUCTION_QOI_SCHEMA4_WINDOWS
    ns = JutulDarcy.PRODUCTION_QOI_SCHEMA4_SLICES
    nfault = nw*ns
    nc = nfault + 2*ns
    atomic_regions = [
        JutulDarcy.ProductionQoIRegion(
            "fault_atomic", "Fault", "atomic", UInt8[1], "", "", "Fault."
        ),
        JutulDarcy.ProductionQoIRegion(
            "seal_atomic", "Seal", "atomic", UInt8[2], "", "", "Seal."
        ),
        JutulDarcy.ProductionQoIRegion(
            "over_atomic", "Overburden", "atomic", UInt8[3], "", "", "Overburden."
        )
    ]
    regions = vcat(
        atomic_regions,
        [
            JutulDarcy.ProductionQoIRegion(
                "fault_all", "Fault", "aggregate", UInt8[1], "", "", "Fault."
            ),
            JutulDarcy.ProductionQoIRegion(
                "top_seal_system", "Top seal", "aggregate", UInt8[2], "", "", "Seal."
            ),
            JutulDarcy.ProductionQoIRegion(
                "overburden_mmum_younger", "Overburden", "aggregate", UInt8[3], "", "", "Overburden."
            )
        ]
    )
    atomic_code = vcat(
        fill(UInt8(1), nfault),
        fill(UInt8(2), ns),
        fill(UInt8(3), ns)
    )
    centroids = zeros(Float64, 3, nc)
    for window in 1:nw
        for slice in 1:ns
            cell = (window - 1)*ns + slice
            centroids[:, cell] .= (slice, 0.0, -10.0*window)
        end
    end
    for slice in 1:ns
        centroids[:, nfault + slice] .= (slice, 0.1, -70.0)
        centroids[:, nfault + ns + slice] .= (slice, -0.1, -80.0)
    end
    mobility = JutulDarcy.ProductionQoIGasMobilityAccounting(
        :drainage,
        zeros(nc),
        zeros(nc),
        ones(nc),
        ones(nc),
        NaN,
        NaN,
        0.0,
        1.0e-10
    )
    context = JutulDarcy.ProductionQoIContext(
        "required", "", "", "", "schema4_fixture", "manifest",
        atomic_code, atomic_regions, regions,
        Dict(region.id => index for (index, region) in enumerate(regions)),
        JutulDarcy.ProductionQoIInterface[], Int32[], Int32[],
        fill(1.0e7, nc), ones(nc), centroids, mobility,
        zeros(length(atomic_regions)), 0.0, "", "", "", "", nothing
    )
    fault = Dict{String, Any}(
        "cells" => collect(1:nfault),
        "window_index" => repeat(collect(1:nw), inner = ns),
        "slice_index" => repeat(collect(1:ns), nw)
    )
    groups, group_pv = JutulDarcy.production_qoi_schema4_fault_groups(
        context,
        Dict{String, Any}("qoi_fault" => fault)
    )
    leakage_cells, leakage_region, leakage_slice =
        JutulDarcy.production_qoi_schema4_leakage_mapping(context, groups)
    context.schema4 = (
        fault_groups = groups,
        fault_group_pore_volume = group_pv,
        leakage_cells = leakage_cells,
        leakage_region = leakage_region,
        leakage_slice = leakage_slice,
        stratigraphic_unit = zeros(Int16, nc),
        stratigraphic_side = zeros(Int8, nc)
    )
    sg = collect(range(0.01, 0.20; length = nc))
    state = Dict{Symbol, Any}(
        :FluidVolume => ones(nc),
        :Saturations => permutedims(hcat(1.0 .- sg, sg)),
        :PhaseMassDensities => vcat(fill(1000.0, 1, nc), fill(2.0, 1, nc)),
        :Rs => fill(0.02, nc),
        :ShrinkageFactors => ones(2, nc),
        :Pressure => collect(range(1.0e7, 1.1e7; length = nc)),
        :CapillaryPressure => collect(range(1.0e4, 2.0e4; length = nc)),
        :MaxSaturations => permutedims(hcat(1.0 .- sg, min.(sg .+ 0.02, 1.0)))
    )
    return context, state
end

@testset "schema-4 compact spatial history" begin
    context, state = schema4_spatial_fixture()
    fault, leakage = JutulDarcy.production_qoi_schema4_spatial_snapshot(
        context,
        state
    )
    @test size(fault) == (6*87, 7)
    @test size(leakage) == (2, 87, 3)
    @test all(isfinite, fault)
    @test all(isfinite, leakage)
    @test fault[1, 3] ≈ state[:Saturations][2, 1]
    @test fault[1, 4] ≈ state[:MaxSaturations][2, 1]
    @test all(leakage[:, :, 1] .> 0.0)
    migration = JutulDarcy.production_qoi_schema4_migration(context, state)
    @test length(migration) == 3
    @test all(result -> result.highest_fault_window == 6, migration)
    @test all(result -> result.highest_domain_elevation_m == 80.0, migration)

    mktempdir() do directory
        path = joinpath(directory, "step_000007.bin")
        JutulDarcy.production_qoi_schema4_write_binary(
            path,
            7,
            fault,
            leakage
        )
        @test filesize(path) ==
            JutulDarcy.production_qoi_schema4_expected_binary_bytes()
        restored = JutulDarcy.production_qoi_schema4_read_binary(path)
        @test restored.step == 7
        @test restored.fault == fault
        @test restored.leakage == leakage
    end
end

@testset "schema-4 accepted-ministep accounting arithmetic" begin
    @test JutulDarcy.production_qoi_schema4_boundary_rate(
        nothing,
        nothing,
        Dict{Any, Any}(:Reservoir => nothing)
    ) == 0.0

    rates = zeros(Float64, 2, 3, 2)
    rates[1, :, 1] .= (1.0, 2.0, 3.0)
    rates[1, :, 2] .= (0.25, 0.5, 0.75)
    rates[2, :, 1] .= (4.0, 5.0, 9.0)
    cumulative = zeros(size(rates))
    JutulDarcy.production_qoi_schema4_integrate_interface_rates!(
        cumulative,
        rates,
        10.0
    )
    @test cumulative == 10.0.*rates
    JutulDarcy.production_qoi_schema4_integrate_interface_rates!(
        cumulative,
        rates,
        2.5
    )
    @test cumulative == 12.5.*rates
    @test_throws ErrorException begin
        invalid = copy(rates)
        invalid[1] = -1.0
        JutulDarcy.production_qoi_schema4_integrate_interface_rates!(
            cumulative,
            invalid,
            1.0
        )
    end

    balance = JutulDarcy.production_qoi_schema4_mass_balance(
        100.0,
        116.0,
        20.0,
        2.0,
        3.0,
        1.0
    )
    @test balance.expected_domain_mass_kg == 116.0
    @test balance.residual_kg == 0.0
    @test balance.relative_residual == 0.0
end

function schema4_transaction_fixture(root)
    context, state = schema4_spatial_fixture()
    fault, leakage = JutulDarcy.production_qoi_schema4_spatial_snapshot(
        context,
        state
    )
    schema_root = joinpath(root, "qoi_schema4")
    ready = joinpath(schema_root, "ready")
    rows = joinpath(schema_root, "rows")
    spatial_ready = joinpath(schema_root, "spatial_ready")
    spatial_rows = joinpath(schema_root, "spatial_rows")
    mkpath.((ready, rows, spatial_ready, spatial_rows))
    interfaces = [
        JutulDarcy.ProductionQoIInterface(
            id,
            id,
            "from",
            "to",
            "accepted_ministep_semantic_contact",
            Int32[],
            Int8[],
            "test"
        ) for id in JutulDarcy.PRODUCTION_QOI_SCHEMA4_INTERFACE_IDS
    ]
    extension = JutulDarcy.ProductionQoISchema4Context(
        "required",
        schema_root,
        ready,
        rows,
        spatial_ready,
        spatial_rows,
        context.case_key,
        context.campaign_manifest_sha256,
        context.schema4.fault_groups,
        context.schema4.fault_group_pore_volume,
        context.schema4.leakage_cells,
        context.schema4.leakage_region,
        context.schema4.leakage_slice,
        zeros(Int16, length(context.atomic_code)),
        zeros(Int8, length(context.atomic_code)),
        interfaces,
        Int32[],
        Int32[],
        repeat("1", 64),
        repeat("2", 64),
        repeat("3", 64),
        zeros(Float64, 4, 3, 2),
        0.0,
        0.0,
        0.0,
        0.0,
        0,
        0.0,
        0,
        "",
        0.0,
        0.0,
        0.0,
        "requested",
        0.0,
        "kg/s",
        0.0,
        "active",
        0.0,
        "kg/s",
        0.0,
        0.0
    )
    context.schema4 = extension
    summary = dirname(schema_root)
    policy = JutulDarcy.ProductionOutputPolicy(
        root,
        summary,
        joinpath(summary, "rows"),
        joinpath(summary, "retention"),
        [1.0],
        1,
        Set{Int}(),
        Float64[],
        2,
        context.case_key,
        context.campaign_manifest_sha256,
        false,
        0,
        nothing,
        nothing,
        false,
        context
    )
    mkpath.((policy.row_dir, policy.retention_dir))
    return context, policy, fault, leakage
end

function schema4_transaction_row(context, spatial_path; step = 1)
    entries = Pair{Symbol, Any}[
        :schema_version => 4,
        :step => step,
        :time_seconds => 1.0,
        :case_key => context.case_key,
        :mapping_sha256 => context.schema4.mapping_sha256,
        :spatial_binary_bytes => filesize(spatial_path),
        :spatial_binary_sha256 =>
            JutulDarcy.production_qoi_file_sha256(spatial_path),
        :cumulative_injected_co2_kg => 10.0,
        :cumulative_produced_co2_kg => 1.0,
        :cumulative_boundary_out_co2_kg => 2.0,
        :cumulative_boundary_in_co2_kg => 0.5,
        :domain_co2_mass_kg => 7.5,
        :expected_domain_co2_mass_kg => 7.5,
        :mass_balance_residual_kg => 0.0,
        :mass_balance_relative_residual => 0.0,
        :accepted_ministep_count => 3,
        :accepted_seconds => 1.0,
        :control_switch_count => 1,
        :active_control => "active",
        :actual_co2_rate_kg_s => 1.0,
        :total_well_mass_rate_kg_s => 1.0,
        :injector_bhp_pa => 1.0e7,
        :requested_control => "requested",
        :requested_target_value => 1.0,
        :requested_target_unit => "kg/s",
        :requested_target_co2_rate_kg_s => 1.0,
        :active_target_value => 1.0,
        :active_target_unit => "kg/s",
        :active_target_co2_rate_kg_s => 1.0,
        :ministep_accounting_seconds => 0.01
    ]
    for interface in context.schema4.interfaces
        for component in ("free", "dissolved", "total")
            prefix = "cumulative_$(interface.id)_$(component)"
            push!(entries, Symbol(prefix * "_forward_kg") => 2.0)
            push!(entries, Symbol(prefix * "_reverse_kg") => 0.5)
            push!(entries, Symbol(prefix * "_net_kg") => 1.5)
        end
    end
    return (; entries...)
end

@testset "schema-4 report transaction recovers a partial atomic commit" begin
    mktempdir() do root
        context, policy, fault, leakage = schema4_transaction_fixture(root)
        extension = context.schema4
        staged_binary = JutulDarcy.production_qoi_schema4_spatial_ready_path(
            extension,
            1
        )
        staged_scalar = JutulDarcy.production_qoi_schema4_ready_path(
            extension,
            1
        )
        JutulDarcy.production_qoi_schema4_write_binary(
            staged_binary,
            1,
            fault,
            leakage
        )
        JutulDarcy.production_write_named_row(
            staged_scalar,
            schema4_transaction_row(context, staged_binary)
        )
        write(JutulDarcy.production_restart_path(policy, 1), "checkpoint")

        committed_binary =
            JutulDarcy.production_qoi_schema4_spatial_row_path(extension, 1)
        mv(staged_binary, committed_binary)
        JutulDarcy.production_reconcile_qoi_schema4!(context, policy, 1)

        @test !isfile(staged_scalar)
        @test isfile(JutulDarcy.production_qoi_schema4_row_path(extension, 1))
        @test isfile(committed_binary)
        @test extension.accepted_ministep_count == 3
        @test extension.cumulative_injected_co2_kg == 10.0
        @test all(extension.cumulative_interface_kg[:, :, 1] .== 2.0)
        @test all(extension.cumulative_interface_kg[:, :, 2] .== 0.5)
        JutulDarcy.production_consolidate_qoi_schema4!(
            context;
            require_complete = true,
            final_schedule_step = 1
        )
        completion = JutulDarcy.production_read_named_row(
            joinpath(extension.root_dir, "QOI_SCHEMA4_COMPLETE.tsv")
        )
        @test completion["storage_budget_passed"] == "true"
        @test parse(Int, completion["payload_bytes_before_completion_marker"]) <=
            parse(Int, completion["storage_budget_bytes"])
    end
end
