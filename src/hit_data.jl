# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

"""
    read_hit_cal(l200::LegendData, det, runs, e_types::AbstractVector{Symbol}, expressions = String[], aoe_types = Symbol[],
                 lq_types = Symbol[]; cuts::Bool = false, <stage>_pars_type::Symbol, <stage>_pars_cat::Symbol, kwargs...)

Read the single-pulse, non-pulser events (`jlqcs` tier) of the `cal` data of detector `det`
for each `(period, run)` in `runs` and return them as one `Table`.

The table has a column for each calibrated energy in `e_types` (e.g. `:e_cusp_ctc_cal`),
calibrated with the calibration function of the energy without the `_cal` suffix, a `timestamp`
column, and the `jldsp` columns that `expressions` (e.g. the A/E functions of the PSD config)
use. An expression may also use the calibrated energies.

For each type in `aoe_types` and `lq_types` the table also has its classifier `<type>_classifier`,
and with `cuts` its cut flag (`<classifier>_low_cut` for A/E, `<classifier>_high_cut` for LQ).

The calibration functions and cut flags are those of `calibrate_ged_detector_data`, from the
parameters of each run that its keywords `<stage>_pars_type` and `<stage>_pars_cat` select for the
stages `e_cal` (default `rpars.ecal`), `aoe_cal`, `aoe_cut` (`ppars.aoe`), `lq_cal` and `lq_cut`
(`ppars.lq`). Only the `jldsp` columns the functions need are read. Other keywords of
`calibrate_ged_detector_data` (e.g. from `get_ged_evt_kwargs`) are ignored, so a misspelled
parameter keyword falls back to its default.
"""
function read_hit_cal(l200::LegendData, det, runs, e_types::AbstractVector{Symbol}, expressions = String[], aoe_types = Symbol[],
                      lq_types = Symbol[]; cuts::Bool = false, e_cal_pars_type::Symbol = :rpars, e_cal_pars_cat::Symbol = :ecal,
                      aoe_cal_pars_type::Symbol = :ppars, aoe_cal_pars_cat::Symbol = :aoe, aoe_cut_pars_type::Symbol = :ppars,
                      aoe_cut_pars_cat::Symbol = :aoe, lq_cal_pars_type::Symbol = :ppars, lq_cal_pars_cat::Symbol = :lq,
                      lq_cut_pars_type::Symbol = :ppars, lq_cut_pars_cat::Symbol = :lq, kwargs...)
    columns_out = union([:timestamp], _input_columns(ljl_propfunc.(expressions)))
    detector = DetectorId(det)
    aoe_classifiers, lq_classifiers = Symbol.(string.(aoe_types) .* "_classifier"), Symbol.(string.(lq_types) .* "_classifier")
    tables = map(collect(runs)) do (period, run)
        sel = start_filekey(l200, (period, run, :cal))
        # Not the public `get_ged_cal_propfunc`, `get_ged_psd_propfunc` and cut functions: each compiles one
        # function over all configured types, which needs the jldsp columns of all of them. The expressions
        # of the requested types alone keep the read to the columns they use. LegendDataManagement keeps
        # the parsed parameters of each run in the process.
        psd_funcs = [[c =>
                          ljl_propfunc(LegendDataManagement._get_aoe_cal_propfunc_str(l200, sel, detector, t; pars_type = aoe_cal_pars_type,
                                                                                      pars_cat = aoe_cal_pars_cat))
                      for (t, c) in zip(aoe_types, aoe_classifiers)];
                     [c =>
                          ljl_propfunc(LegendDataManagement._get_lq_cal_propfunc_str(l200, sel, detector, t; pars_type = lq_cal_pars_type,
                                                                                     pars_cat = lq_cal_pars_cat))
                      for (t, c) in zip(lq_types, lq_classifiers)]]
        cut_funcs = !cuts ? [] :
                    [[Symbol("$(c)_low_cut") =>
                          ljl_propfunc(LegendDataManagement._get_ged_aoe_lowcut_propfunc_str(l200, sel, detector, c;
                                                                                             pars_type = aoe_cut_pars_type,
                                                                                             pars_cat = aoe_cut_pars_cat))
                      for c in aoe_classifiers];
                     [Symbol("$(c)_high_cut") =>
                          ljl_propfunc(LegendDataManagement._get_ged_lq_highcut_propfunc_str(l200, sel, detector, c;
                                                                                             pars_type = lq_cut_pars_type,
                                                                                             pars_cat = lq_cut_pars_cat))
                      for c in lq_classifiers]]
        # The classifiers may use other calibrated energies, named `<energy>_cal` as in `get_ged_cal_propfunc`.
        cal_types = union(e_types, filter(col -> endswith(string(col), "_cal"), _input_columns(last.(psd_funcs))))
        cal_funcs = [e_type => ljl_propfunc(LegendDataManagement._get_e_cal_propsfunc_str(l200, sel, detector,
                                                                                          Symbol(chopsuffix(string(e_type), "_cal"));
                                                                                          pars_type = e_cal_pars_type, pars_cat = e_cal_pars_cat))
                     for e_type in cal_types]
        # Each stage uses the outputs of the previous ones, as in `calibrate_ged_detector_data`.
        stages = (cal_funcs, psd_funcs, cut_funcs)
        outputs = [name for stage in stages for (name, _) in stage]
        columns_dsp = setdiff(union(columns_out, _input_columns([f for stage in stages for (_, f) in stage])), outputs)
        hit = Table(read_ldata(Tuple(columns_dsp), l200, :jldsp, :cal, period, run, det;
                               filterby = :jlqcs => @pf($is_single_pulse && !$is_pulser)))
        for stage in stages
            hit = Table(merge(columns(hit), NamedTuple(name => f.(hit) for (name, f) in stage)))
        end
        # Only the requested columns, so that the tables of all runs have the same columns.
        return Table(columns(hit)[Tuple(union(columns_out, e_types, first.(psd_funcs), first.(cut_funcs)))])
    end
    return fast_flatten(tables)
end

# The names of the columns that the property functions `pfs` read
_input_columns(pfs) = unique(Symbol[_input_column(path) for pf in pfs for path in PropertyFunctions.input_property_paths(pf)])
_input_column(::PropertyFunctions.PPath{path}) where {path} = first(path)
