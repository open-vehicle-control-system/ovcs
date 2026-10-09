# This file contains the configuration for Credo and you are probably reading
# this after creating it with `mix credo.gen.config`.
#
# If you find anything wrong or unclear in this file, please report an
# issue on GitHub: https://github.com/rrrene/credo/issues
#
%{
  #
  # You can have as many configs as you like in the `configs:` field.
  configs: [
    %{
      #
      # Run any config using `mix credo -C <name>`. If no config name is given
      # "default" is used.
      #
      name: "default",
      #
      # These are the files included in the analysis:
      files: %{
        #
        # You can give explicit globs or simply directories.
        # In the latter case `**/*.{ex,exs}` will be used.
        #
        included: ["lib/", "src/", "test/", "web/"],
        excluded: [
          ~r"/_build/",
          ~r"/deps/",
          ~r"/node_modules/",
          ~r"/libraries/(cantastic|express_lrs|msp_osd)/"
        ]
      },
      #
      # Load and configure plugins here:
      #
      plugins: [],
      #
      # If you create your own checks, you must specify the source files for
      # them here, so they can be loaded by Credo before running the analysis.
      #
      # Every Mix project sits two levels below the repo root.
      requires: ["../../.credo/checks/"],
      #
      # If you want to enforce a style guide and need a more traditional linting
      # experience, you can change `strict` to `true` below:
      #
      strict: true,
      #
      # To modify the timeout for parsing files, change this value:
      #
      parse_timeout: 5000,
      #
      # If you want to use uncolored output by default, you can change `color`
      # to `false` below:
      #
      color: true,
      #
      # You can customize the parameters of any check by adding a second element
      # to the tuple.
      #
      # To disable a check put `false` as second element:
      #
      #     {Credo.Check.Design.DuplicatedCode, false}
      #
      checks: %{
        enabled: [
          #
          ## Consistency Checks
          #
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          #
          ## Design Checks
          #
          # You can customize the priority of any check
          # Priority values are: `low, normal, high, higher`
          #
          # Aggressive default (if_nested_deeper_than: 2) fires on nearly every
          # Phoenix/Nerves module. Raised to reduce noise without disabling.
          {Credo.Check.Design.AliasUsage,
           [priority: :low, if_nested_deeper_than: 4, if_called_more_often_than: 3]},
          {Credo.Check.Design.TagFIXME, []},
          # You can also customize the exit_status of each check.
          # If you don't want TODO comments to cause `mix credo` to fail, just
          # set this value to 0 (zero).
          #
          # TODOs are notes, not CI blockers. Flag them but don't fail.
          {Credo.Check.Design.TagTODO, [exit_status: 0]},

          #
          ## Readability Checks
          #
          # Alphabetical alias ordering is a style preference; opt-in when
          # the codebase is ready for a sweep.
          {Credo.Check.Readability.AliasOrder, false},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 200]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc,
           [
             files: %{
               included: ["lib/"],
               # Cleanup pending; a cleaned file leaves the list.
               excluded: [
                 "lib/infotainment_api_web/channels/metrics_channel.ex",
                 "lib/infotainment_core/temperature.ex",
                 "lib/obd2/infotainment/composer/infotainment.ex",
                 "lib/obd2/infotainment/composer/infotainment/blocks/speed_gauge_block.ex",
                 "lib/obd2/infotainment/composer/infotainment/blocks/time_settings_block.ex",
                 "lib/obd2/infotainment/composer/infotainment/dashboard_page.ex",
                 "lib/obd2/infotainment/composer/infotainment/settings_page.ex",
                 "lib/obd2/vms/composer/dashboard.ex",
                 "lib/obd2/vms/composer/dashboard/dashboard_page.ex",
                 "lib/obd2/vms/composer/dashboard/discovery_page.ex",
                 "lib/obd2/vms/composer/dashboard/dtcs_page.ex",
                 "lib/obd2/vms/composer/dashboard/live_data_page.ex",
                 "lib/obd2/vms/composer/dashboard/vehicle_info_page.ex",
                 "lib/ovcs1/infotainment.ex",
                 "lib/ovcs1/infotainment/composer/infotainment.ex",
                 "lib/ovcs1/infotainment/composer/infotainment/blocks/battery_overview_block.ex",
                 "lib/ovcs1/infotainment/composer/infotainment/blocks/car_overview_block.ex",
                 "lib/ovcs1/infotainment/composer/infotainment/blocks/gear_selector_block.ex",
                 "lib/ovcs1/infotainment/composer/infotainment/blocks/speed_gauge_block.ex",
                 "lib/ovcs1/infotainment/composer/infotainment/blocks/status_grid_block.ex",
                 "lib/ovcs1/infotainment/composer/infotainment/blocks/time_settings_block.ex",
                 "lib/ovcs1/infotainment/composer/infotainment/dashboard_page.ex",
                 "lib/ovcs1/infotainment/composer/infotainment/settings_page.ex",
                 "lib/ovcs1/vms/composer/dashboard.ex",
                 "lib/ovcs1/vms/composer/dashboard/battery_page.ex",
                 "lib/ovcs1/vms/composer/dashboard/blocks/throttle_chart.ex",
                 "lib/ovcs1/vms/composer/dashboard/blocks/torque_chart.ex",
                 "lib/ovcs1/vms/composer/dashboard/brake_booster_page.ex",
                 "lib/ovcs1/vms/composer/dashboard/dashboard_page.ex",
                 "lib/ovcs1/vms/composer/dashboard/generic_controllers_page.ex",
                 "lib/ovcs1/vms/composer/dashboard/inverter_page.ex",
                 "lib/ovcs1/vms/composer/dashboard/radio_control_page.ex",
                 "lib/ovcs1/vms/composer/dashboard/ros_control_page.ex",
                 "lib/ovcs1/vms/composer/dashboard/steering_column_page.ex",
                 "lib/ovcs1/vms/composer/dashboard/throttle_pedal_page.ex",
                 "lib/ovcs_mini/vms/composer/dashboard.ex",
                 "lib/ovcs_mini/vms/composer/dashboard/blocks/radio_control_throttle_and_steering.ex",
                 "lib/ovcs_mini/vms/composer/dashboard/blocks/ros_control_throttle_and_steering.ex",
                 "lib/ovcs_mini/vms/composer/dashboard/dashboard_page.ex",
                 "lib/ovcs_mini/vms/composer/dashboard/drivetrain_page.ex",
                 "lib/ovcs_mini/vms/composer/dashboard/generic_controllers_page.ex",
                 "lib/ovcs_mini/vms/composer/dashboard/radio_control_page.ex",
                 "lib/ovcs_mini/vms/composer/dashboard/ros_control_page.ex",
                 "lib/radio_control_bridge/mavlink_forwarder.ex",
                 "lib/radio_control_bridge/msp_osd_forwarder.ex",
                 "lib/ros_bridge/consumers/joy.ex",
                 "lib/ros_bridge/consumers/velocity.ex",
                 "lib/vms_api_web/channels/metrics_channel.ex",
                 "lib/vms_api_web/channels/network_interfaces_channel.ex",
                 "lib/vms_core/pid.ex",
                 "lib/vms_firmware/util/network_mapper.ex"
               ]
             }
           ]},
          {Credo.Check.Readability.ModuleNames, []},
          {Ovcs.Credo.Check.CommentBlocks,
           [
             files: %{
               included: ["lib/"],
               # Cleanup pending; a cleaned file leaves the list.
               excluded: [
                 "lib/bno085/i2c.ex",
                 "lib/bridge_firmware/application.ex",
                 "lib/infotainment_api_web/controllers/error_json.ex",
                 "lib/infotainment_api_web/endpoint.ex",
                 "lib/infotainment_api_web/router.ex",
                 "lib/infotainment_firmware.ex",
                 "lib/obd2/vms/discovery.ex",
                 "lib/ovcs1.ex",
                 "lib/ovcs1/vms/composer.ex",
                 "lib/ovcs_bridge/supervisor.ex",
                 "lib/ovcs_bus/distribution.ex",
                 "lib/ovcs_bus/units.ex",
                 "lib/ovcs_mini.ex",
                 "lib/ovcs_mini/vms/composer.ex",
                 "lib/ovcs_vehicle/firmware.ex",
                 "lib/ovcs_vehicle/firmware_validator.ex",
                 "lib/ovcs_vehicle/scaffold.ex",
                 "lib/radio_control_bridge.ex",
                 "lib/ros2/cdr.ex",
                 "lib/ros2/common.ex",
                 "lib/ros2/geometry_msgs/msg/twist.ex",
                 "lib/ros2/geometry_msgs/msg/twist_stamped.ex",
                 "lib/ros2/geometry_msgs/msg/vector3.ex",
                 "lib/ros2/nav_msgs/msg/odometry.ex",
                 "lib/ros2/rosgraph_msgs/msg/clock.ex",
                 "lib/ros2/sensor_msgs/msg/imu.ex",
                 "lib/ros2/sensor_msgs/msg/joy.ex",
                 "lib/ros2/sensor_msgs/msg/range.ex",
                 "lib/ros2/std_msgs/msg/string.ex",
                 "lib/ros2/tf2_msgs/msg/tf_message.ex",
                 "lib/ros2/vision_msgs/msg/detection3d.ex",
                 "lib/ros2/visualization_msgs/msg/marker.ex",
                 "lib/ros_bridge.ex",
                 "lib/ros_bridge/camera/calibration.ex",
                 "lib/ros_bridge/camera/gstreamer.ex",
                 "lib/ros_bridge/camera/lib_camera.ex",
                 "lib/ros_bridge/camera/mjpeg_stream.ex",
                 "lib/ros_bridge/clock.ex",
                 "lib/ros_bridge/components.ex",
                 "lib/ros_bridge/consumers/joy.ex",
                 "lib/ros_bridge/consumers/velocity.ex",
                 "lib/ros_bridge/inference/dnn.ex",
                 "lib/ros_bridge/inference/hailo.ex",
                 "lib/ros_bridge/inference/supervisor.ex",
                 "lib/ros_bridge/input_watchdog.ex",
                 "lib/ros_bridge/parameters.ex",
                 "lib/ros_bridge/perception/fusion.ex",
                 "lib/ros_bridge/publishers/detections.ex",
                 "lib/ros_bridge/publishers/odometry.ex",
                 "lib/ros_bridge/publishers/stereo_camera.ex",
                 "lib/ros_bridge/stereo_camera/open_cv.ex",
                 "lib/ros_bridge/stereo_camera/supervisor.ex",
                 "lib/ros_bridge/stereo_camera/telemetry.ex",
                 "lib/ros_bridge/timing.ex",
                 "lib/rplidar/uart.ex",
                 "lib/vms_api_web/controllers/error_json.ex",
                 "lib/vms_api_web/endpoint.ex",
                 "lib/vms_api_web/router.ex",
                 "lib/vms_core/application.ex",
                 "lib/vms_core/components/bosch/i_booster_gen2.ex",
                 "lib/vms_core/components/nissan/leaf_aze0/inverter.ex",
                 "lib/vms_core/components/ovcs/generic_controller.ex",
                 "lib/vms_core/components/ovcs/input_curve.ex",
                 "lib/vms_core/components/ovcs/radio_control/throttle.ex",
                 "lib/vms_core/components/ovcs/ros_velocity_command.ex",
                 "lib/vms_core/components/ovcs/rotation_fusion.ex",
                 "lib/vms_core/components/traxxas/motor_controller.ex",
                 "lib/vms_core/components/traxxas/steering.ex",
                 "lib/vms_core/components/vesc/motor_controller.ex",
                 "lib/vms_core/managers/control_level.ex",
                 "lib/vms_core/managers/gear.ex",
                 "lib/vms_core/status.ex",
                 "lib/vms_firmware/application.ex",
                 "lib/zenoh_client.ex"
               ]
             }
           ]},
          {Ovcs.Credo.Check.CommentRatio,
           [
             files: %{
               included: ["lib/"],
               # Cleanup pending; a cleaned file leaves the list.
               excluded: [
                 "lib/infotainment_api_web/controllers/error_json.ex",
                 "lib/infotainment_firmware.ex",
                 "lib/ovcs_mini.ex",
                 "lib/ovcs_mini/vms/composer.ex",
                 "lib/ros2/common.ex",
                 "lib/ros2/tf2_msgs/msg/tf_message.ex",
                 "lib/ros_bridge.ex",
                 "lib/ros_bridge/components.ex",
                 "lib/ros_bridge/stereo_camera/open_cv.ex",
                 "lib/vms_api_web/controllers/error_json.ex",
                 "lib/vms_firmware/application.ex"
               ]
             }
           ]},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          # Community is split on zero-arity parens; opt-in when project wants it.
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, false},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithSingleClause, []},

          #
          ## Refactoring Opportunities
          #
          {Credo.Check.Refactor.Apply, []},
          # Single-clause cond is idiomatic in places (matches multi-clause patterns).
          {Credo.Check.Refactor.CondStatements, false},
          # Existing VMS state-machine selectors (gear, control_level) exceed
          # the default max of 9. Raise to match what's in tree today; drop
          # back to 9 when those are refactored.
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 25]},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.WithClauses, []},

          #
          ## Warnings
          #
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFileExtension, []}
        ],
        disabled: [
          #
          # Checks scheduled for next check update (opt-in for now)
          {Credo.Check.Refactor.UtcNowTruncate, []},

          #
          # Controversial and experimental checks (opt-in, just move the check to `:enabled`
          #   and be sure to use `mix credo --strict` to see low priority checks)
          #
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Credo.Check.Consistency.UnusedVariableNames, []},
          {Credo.Check.Design.DuplicatedCode, []},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Readability.AliasAs, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Readability.NestedFunctionCalls, []},
          {Credo.Check.Readability.OneArityFunctionInPipe, []},
          {Credo.Check.Readability.OnePipePerLine, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Refactor.ABCSize, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.IoPuts, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.ModuleDependencies, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.RejectFilter, []},
          {Credo.Check.Refactor.VariableRebinding, []},
          {Credo.Check.Warning.LazyLogging, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.UnsafeToAtom, []}

          # {Credo.Check.Refactor.MapInto, []},

          #
          # Custom checks can be created using `mix credo.gen.check`.
          #
        ]
      }
    }
  ]
}
