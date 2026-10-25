"""
    process_peak_split_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun;
        reprocess::Bool=false, timeout::Real=0)

Extract the events in the peaks of the `phy` raw config, such as the K-40 and K-42 lines,
from the raw `phy` data of the HPGe detectors (`geds`) of a run.

The same as [`process_peak_split_cal`](@ref) for the `phy` files of the run. The DAQ energy
is calibrated with the parameters of [`process_daq_energy_calibration_cal`](@ref) of the
`cal` data of the same run.

# Inputs
- `raw` tier of the `phy` filekeys of the run listed in the runinfo, except the filekeys marked unprocessable
- `l200.par.rpars.daqecal[period, run]`: DAQ energy calibration function `func` per detector
- `dataprod_config(l200).raw(filekey)` for the `phy` filekey, sections `default` and per detector, entry `peaks`

# Outputs
- `jlpks` tier file of the start `phy` filekey of the run for each detector, with one table per entry of `peaks`
- run report `:peak_split_phy`, with one row per detector (number of events per peak, time, allocations)

# Keywords
- `reprocess`: recreate the `jlpks` files; otherwise a detector with a readable `jlpks` file is skipped (an unreadable file is removed and recreated)
- `timeout`: seconds allowed per detector in `parallel` (0 = no limit)
- `use_cache`: write each output file to a local cache directory first and move it to its place when done; otherwise write it next to its final location (default: `false`)

# Returns
Return `nothing`.
"""
function process_peak_split_phy(processing_config, l200::LegendData, period::DataPeriod, run::DataRun; reprocess::Bool = false,
                                timeout::Real = 0, use_cache::Bool = false)
    return split_peaks(l200, period, run, :phy, :process_peak_split_phy; reprocess, timeout, use_cache)
end

register_processor!(process_peak_split_phy; output_tiers = [:jlpks])
