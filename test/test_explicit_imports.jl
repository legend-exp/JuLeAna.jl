# This file is a part of JuLeAna.jl, licensed under the MIT License (MIT).

import Test
import ExplicitImports
import JuLeAna

Test.@testset "ExplicitImports" begin
    ExplicitImports.test_explicit_imports(JuLeAna;
                                          ignore = (
                                                    # Logging interface methods: documented extension points, not marked public.
                                                    :catch_exceptions, :handle_message, :min_enabled_level, :shouldlog,
                                                    # The only way to list the keywords a method declares (`check_processor_kwargs`).
                                                    :kwarg_decl,
                                                    # Evaluated in `Main` on every process by `@always_everywhere` in `main`.
                                                    :init_process,
                                                    # Tachikoma's model interface: documented extension points, not marked public.
                                                    :should_quit, :update!, :view, :init!, :cleanup!, :task_queue,
                                                    # ProgressLogging's progress record, documented for logging bars but not marked public.
                                                    :Progress,
                                                    # The only source of GC counts and pause times, for the interface timing (`InterfaceTiming`).
                                                    :gc_num, :GC_Num,
                                                    # The exception of a failed `readdir`, for the path completion (`complete_path`).
                                                    :IOError,
                                                    # Base's check of `JULIA_DEBUG`, also used by LoggingExtras (`ProcessorLevelLogger`).
                                                    :CoreLogging, :env_override_minlevel,
                                                    # Non-public names of the LEGEND and utility packages used by the processors.
                                                    :fast_flatten, :set_timelimit, :_fix_vov, :AchatBlue, :BEGeOrange, :CoaxGreen,
                                                    :add_watermarks!, :parameterplot!, :tottime, :totallocated, :format_bytes,
                                                    # Cached calibration function of one energy type (`read_hit_cal`).
                                                    :_get_e_cal_propsfunc_str))
end # testset
