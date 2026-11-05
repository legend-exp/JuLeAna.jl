"""
    process_peak_split_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Extract the events in the Th-228 peaks from the raw `cal` data of the HPGe detectors (`geds`) of a run.

For each detector, the DAQ energy of the raw `cal` files of the run listed in the runinfo, except the filekeys
marked unprocessable, is calibrated with the parameters of
[`process_daq_energy_calibration_cal`](@ref), and the events inside the energy windows given
by `peaks` (for example `Tl208FEP` and `Tl208SEP`) are written with their raw waveforms. A
detector without DAQ energy calibration fails. The processor throws an error if no file is
found.

# Inputs
- `raw` tier of the `cal` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `l200.par.rpars.daqecal[period, run]`: DAQ energy calibration function `func` per detector
- `dataprod_config(l200).raw(filekey)`, sections `default` and per detector, entry `peaks`

# Outputs
- `jlpks` tier file of the start filekey of the run for each detector, with one table per entry of `peaks`
- run report `:peak_split`, with one row per detector (number of events per peak, time, allocations)

# Keywords
- `reprocess`: recreate the `jlpks` files; otherwise a detector with a readable `jlpks` file is skipped (an unreadable file is removed and recreated)
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit)
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `false`)

# Returns
Return `nothing`.
"""
function process_peak_split_cal(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                timeout::Real = 0, use_cache::Bool = false)
    return split_peaks(processing_config, l200, period, run, :cal, :process_peak_split_cal; reprocess, timeout, use_cache)
end

register_processor!(process_peak_split_cal; output_tiers = [:jlpks])
