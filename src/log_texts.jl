# helper functions for logging
"""
    detector_status(usability::Symbol)

Return `usability` as an HTML `<span>` string for Markdown reports, colored green for
`:on`, yellow for `:ac`, red for `:off` and gray for any other value.
"""
function detector_status(usability::Symbol)
    color = get((on = "green", ac = "yellow", off = "red"), usability, "gray")
    return """<span style="color:$color">$usability</span>"""
end

"""
    process_skipped

Report status of an item that a partition step leaves to the same step of the period in
which the partition starts (`only_first_period`): `Skipped` as an HTML `<span>` string for
Markdown reports, in gray. [`master_status`](@ref) counts it as a success.
"""
const process_skipped = """<span style="color:gray">Skipped</span>"""

"""
    master_status(results...)

Combine the report rows of a processor into one status: `process_succeeded`,
`process_warning` or `process_failed`.

Each element of `results` is a collection of `itr => res` pairs as returned by
[`parallel`](@ref), or `nothing`, which is ignored. `res.log` is a report row with a
`Status` field, or a `Dict` of such rows. When a row has a `usability` column, the
detector usability is read from `itr.usability`; otherwise the row counts as `:on`.

| Row status | `:on` | `:ac` | `:off` |
|:-----------|:------|:------|:-------|
| success    | –     | –     | –      |
| skipped    | –     | –     | –      |
| warning    | fail  | warn  | –      |
| failure    | fail  | fail  | warn   |

The result is `process_failed` if any row fails, otherwise `process_warning` if any row
warns, otherwise `process_succeeded`. Without any rows the result is `process_failed`.
"""
function master_status(results...)
    status = process_succeeded
    has_entries = false
    for result in results
        isnothing(result) && continue
        for (itr, res) in result
            logs = res.log isa Dict ? values(res.log) : (res.log,)
            for log in logs
                has_entries = true
                usability = haskey(log, :usability) ? itr.usability : :on
                if log.Status == process_succeeded || log.Status == process_skipped || (usability == :off && log.Status == process_warning)
                    continue
                elseif (usability == :ac && log.Status == process_warning) || (usability == :off && log.Status == process_failed)
                    status = process_warning
                else
                    return process_failed
                end
            end
        end
    end
    return has_entries ? status : process_failed
end

# Current UTC time as ISO 8601 with a `Z` suffix, for log directory names and reports.
utc_timestamp() = Dates.format(now(UTC), dateformat"yyyy-mm-ddTHH:MM:SS\Z")

"""
    truncate_string(s::AbstractString, max_length::Integer=1000)

Return `s` if it has at most `max_length` characters, otherwise its first `max_length`
characters followed by `"..."`.

# Examples
```jldoctest
julia> truncate_string("process_dsp_cal", 7)
"process..."
```
"""
function truncate_string(s::AbstractString, max_length::Integer = 1000)
    return length(s) > max_length ? first(s, max_length) * "..." : s
end

"""
    root_exception(e)

Return the exception that caused `e`: `CompositeException` (its first entry),
`TaskFailedException`, `RemoteException` and `CapturedException` are unwrapped, also when
nested. Other exceptions are returned unchanged.
"""
root_exception(e) = e
root_exception(e::CompositeException) = root_exception(first(e.exceptions))
root_exception(e::TaskFailedException) = root_exception(e.task.exception)
root_exception(e::RemoteException) = root_exception(e.captured)
root_exception(e::CapturedException) = root_exception(e.ex)

"""
    truncate_error(e, max_length::Integer=1000)

Return the text of the [`root_exception`](@ref) of `e`, shortened with
[`truncate_string`](@ref) to `max_length` characters.
"""
function truncate_error(e, max_length::Integer = 1000)
    return truncate_string(string(root_exception(e)), max_length)
end

# Static report sections, one per processor; internal to the module.

const daq_energy_calibration_log_text = """## DAQ Energy Calibration
This is the log for the DAQ energy calibration. The algorithm loads the DAQ online energy of each channel
and calibrates it automatically with the Th-228 lines. The calibration is used by the peak splitting.
"""

const peak_splitting_log_text = """## Peak Splitting
This is the log for the peak splitting. The algorithm calibrates the DAQ online energy of each channel
with the DAQ energy calibration and then splits the waveforms in chunks for each peak of interest.
The chunks are then saved to the `jlpks` file.
"""

const decay_time_log_text = """## Decay Time Extraction
This is the log for the decay time extraction. The algorithm loads the FEP data of each channel.
After a mini DSP, the decay times are extracted by fitting an exponential function to the tail.
Then, the distribution is truncated around the peak to fit a truncated gaussian function.
The centroid of the distribution is extracted as the decay time.
"""

const filter_optimization_log_text = """## Filter Optimization
This is the log for the energy filter optimization. The algorithm loads the FEP data of each channel.
After a mini DSP, the optimal rise time is determined by performing a noise sweep on the baseline and look for minimal ENC with a fixed flat-top time.
Then, the optimal rise time is used for a mini DSP while sweeping through flat-top times and selecting the one which has minimal FWHM at the FEP.
"""

const sg_filter_optimization_log_text = """## SG window length optimization
This is the log for the savitzky-golay filter optimization for the PSD analysis. The processing involves
a small DSP routine on the waveforms in the DEP and SEP, a simple AoE cut for different window lengths
and the calculation of the survival fraction in the SEP after a simple PSD cut on the DEP. Then, the 
window length with the lowest survival fraction is chosen."""

const dsp_cal_log_text = """## DSP
This is the log for the dsp. The algorithm iterates through each file and process within each file each detector separate."""

const qcs_cal_log_text = """## Cal QC generation
QC flags and pulser/Tl-208 FEP survival fractions are saved for each detector.
The report counts single-pulse events failing the metadata's is_valid_e check."""

const qcs_phy_log_text = """## Physics QC generation
QC flags and pulser/forced-trigger survival fractions are saved for each detector. Forced triggers exclude pulsers.
The report counts single-pulse events failing the metadata's is_valid_dsp check."""

const energy_ctc_log_text = """## CT Correction
This is the log for the charge trapping correction. The algorithm loads all data for a channel and performs the correction while optimizing maximum height and FWHM of a defined peak in the energy spectrum.
Before the parameters are extracted, QC cuts are applied to increase the quality of the data."""

const energy_log_text = """## Energy Calibration
This is the log for the energy calibration. The algorithm loads all data for a channel and performs a energy calibration while fitting peaks identified in the spectrum and returning 
calibration constant and resolution.
Before the parameters are extracted, QC cuts are applied to increase the quality of the data."""

const aoe_log_text = """## PSD calibration
This is the log for the PSD calibration for the AoE PSD analysis. The processing involves fitting the Compton bands of the AoE spectrum and fitting the resulting parameters with correction functions. The correction functions are then applied to the AoE spectrum. The resulting AoE spectrum is then saved to the hit file.
"""

const energy_partition_log_text = """## Energy Partition Calibration
This is the log for the energy calibration for a partition. The algorithm loads all data for a channel and performs a energy calibration while fitting peaks identified in the spectrum and returning 
calibration constant and resolution for a full partition."""

const aoe_partition_log_text = """## PSD CUT
This is the log for the PSD CUT generation for the AoE PSD analysis. The processing involves 
generating a cut that lets 90% of the events in the Tl-208 DEP pass. The cut is generated by
sweeping through different values of the cut and finding the root with 90% of the original peak counts."""

const psd_efficiencies_log_text = """## PSD efficiencies
This is the log for the PSD efficiencies. The algorithm applies the A/E and LQ cuts to the calibration data of a channel and fits the configured peaks and the Qbb window. The survival fractions of the peaks and of the Qbb window are evaluated for combinations of the A/E and LQ cuts.
"""

const sipm_optimization_log_text = """## SiPM threshold extraction
This is the log for the SiPM threshold extraction. The algorithm loads the physics data for one SiPM channel from a defined number of filekeys.
After a mini DSP, the baseline distributions of the normal and flipped waveforms are extracted by projection on the y-axis.
Then, the distributions are truncated around the peak to fit a truncated gaussian function.
The sigma of the distributions is extracted as the trigger threshold.
"""
const lq_log_text = """## LQ
This is the log for the LQ calibration. The algorithm loads the LQ data for a channel and first performs a energy and drift time correction to construct the lq classifier.
Then, the LQ cut value is generated by fitting a gaussian to the sideband subtracted LQ histogram and extracting the cutoff value at 3 sigma.
"""

const sipm_calibration_log_text = """## SiPM calibration
This is the log for the SiPM calibration. The algorithm loads the physics data for one SiPM channel from a defined number of filekeys.
After a mini DSP, the calibration is performed by fitting the 1 p.e. and 2 p.e. peaks with a gaussian function.
The calibration constant and offset are extracted from the fit.
"""

const evt_log_text = """## Evt
This is the log for the event level. The algorithm iterates through each file each file and generates the event level table for each subsystem including correct calibrations and cut generation."""

const skm_log_text = """## SKM
This is the log for the SKM. The algorithm iterates through each file and generates the SKM level table for each subsystem including correct calibrations and cut generation.
"""

const qc_ml_sampling_log_text = """## QC ML sampling
This is the log for the QC machine-learning sampling. The algorithm scans the raw files of all analysis runs of the period for the configured detectors, draws the training sample by the selection rules of the QC ML config and clusters its waveforms with affinity propagation.
The sample is written to the `jlqml` tier, the unlabeled parameter entry with the cluster exemplars to `rpars/ml`.
"""
