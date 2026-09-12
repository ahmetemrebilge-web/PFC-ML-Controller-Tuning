function result = run_single_pfc_case(caseSpec)
%RUN_SINGLE_PFC_CASE Execute one protected Boost PFC diagnostic simulation.
%
% Default call:
%   result = run_single_pfc_case();
%
% Custom call example:
%   s = struct();
%   s.ScenarioID = "CUSTOM_001";
%   s.Vin_RMS = 230;
%   s.Pload_Pre_W = 300;
%   s.Pload_High_W = 1400;
%   s.KP = 0.010;
%   s.KI = 0.80;
%   s.Profile = "Diagnostic";
%   s.SaveArtifacts = true;
%   result = run_single_pfc_case(s);
%
% Safety contract:
%   - The baseline SLX file is never saved.
%   - The file SHA-256 is checked before and after the run.
%   - Controller, source, load, timing, model, and Scope states are restored.
%   - IAMP_MAX is fixed by pfc_ml_config.m and is not a free ML variable.
%   - Scope blocks are disabled during simulation for R2025a crash safety.
%   - VOUT_MON, IL_RAW, VAC_RAW, DUTY_MON, and IREF_MON are retained with
%     conservative decimation; the fixed-step solver remains at 1e-7 s.
%   - Unused time/output/data-store logs are disabled temporarily.
%   - The Simulation Data Inspector repository is cleared before and after
%     every dedicated automation run so Temp data cannot accumulate.
%
% Required files in the same folder:
%   pfc_ml_config.m
%   run_single_pfc_case.m
%   Boost_PFC_BayesOpt_v1_WORKING_BASELINE.slx
%
% Runner revision: 1.6.0
% MATLAB release: R2025a


%% ============================================================
% LOAD CONFIGURATION AND DEFAULT CASE
%% ============================================================

cfg = pfc_ml_config();

repositoryCleanupGuard = onCleanup(@() ...
    clearSDIRepositoryBestEffort(cfg));

if nargin < 1 || isempty(caseSpec)
    caseSpec = createDefaultCase(cfg);
else
    caseSpec = completeCaseSpec(caseSpec, cfg);
end

validateCaseSpec(caseSpec, cfg);

rng(caseSpec.RandomSeed, 'twister');


%% ============================================================
% LOCATE FILES AND VERIFY BASELINE
%% ============================================================

scriptFullPath = mfilename('fullpath');

if isempty(scriptFullPath)
    error( ...
        'PFCMLSingleCase:ScriptLocationUnknown', ...
        'Save run_single_pfc_case.m before running it.');
end

scriptFolder = fileparts(scriptFullPath);
modelFullPath = fullfile(scriptFolder, cfg.Model.File);

freeSpaceBeforeRun_GB = verifyFreeDiskSpace(scriptFolder, cfg);

if cfg.Storage.ClearSDIRepositoryBeforeEachRun
    clearSDIRepository(cfg);
end

if ~isfile(modelFullPath)
    error( ...
        'PFCMLSingleCase:ModelMissing', ...
        ['Baseline model was not found next to this script:\n%s\n' ...
         'Place the SLX, config, and runner in the same folder.'], ...
        modelFullPath);
end

hashBefore = calculateFileSHA256(modelFullPath);

if ~strcmpi(hashBefore, cfg.Model.ExpectedSHA256)
    error( ...
        'PFCMLSingleCase:BaselineHashMismatch', ...
        ['Baseline SHA-256 does not match pfc_ml_config.m.\n' ...
         'Expected: %s\nActual  : %s\n' ...
         'Do not continue until the model identity is resolved.'], ...
        cfg.Model.ExpectedSHA256, ...
        hashBefore);
end


%% ============================================================
% PREPARE THE MODEL WITHOUT SAVING IT
%% ============================================================

mdl = cfg.Model.Name;
modelWasLoaded = bdIsLoaded(mdl);

if modelWasLoaded && strcmpi(get_param(mdl, 'Dirty'), 'on')
    error( ...
        'PFCMLSingleCase:UnsavedModelChanges', ...
        ['The baseline model is loaded with unsaved changes.\n' ...
         'Save those changes under a different filename or discard them.']);
end

modelLoadedByThisFunction = false;

if ~modelWasLoaded
    load_system(modelFullPath);
    modelLoadedByThisFunction = true;
end

controller = findPFCController(mdl);
originalState = captureOriginalState(mdl, controller, cfg);

cleanupGuard = onCleanup(@() restoreOriginalState( ...
    mdl, ...
    controller, ...
    originalState, ...
    modelLoadedByThisFunction, ...
    cfg));


%% ============================================================
% CALCULATE REQUESTED MODEL PARAMETERS
%% ============================================================

sourceAmplitude_Vpeak = caseSpec.Vin_RMS * sqrt(2.0);

baseResistance_Ohm = ...
    cfg.Physical.TargetVout_V^2 / caseSpec.Pload_Pre_W;

deltaPower_W = ...
    caseSpec.Pload_High_W - caseSpec.Pload_Pre_W;

switchedResistance_Ohm = ...
    cfg.Physical.TargetVout_V^2 / deltaPower_W;

profile = selectProfile(caseSpec.Profile, cfg);


%% ============================================================
% INITIALIZE RESULT
%% ============================================================

result = createEmptyResult( ...
    caseSpec, ...
    cfg, ...
    sourceAmplitude_Vpeak, ...
    baseResistance_Ohm, ...
    switchedResistance_Ohm, ...
    profile, ...
    hashBefore);


%% ============================================================
% PRINT RUN HEADER
%% ============================================================

fprintf('\n');
fprintf('====================================================\n');
fprintf('PFC ML - SINGLE PROTECTED SIMULINK CASE\n');
fprintf('====================================================\n');
fprintf('Scenario ID       : %s\n', char(caseSpec.ScenarioID));
fprintf('Profile           : %s\n', char(caseSpec.Profile));
fprintf('Vin RMS / peak    : %.3f / %.3f V\n', ...
    caseSpec.Vin_RMS, sourceAmplitude_Vpeak);
fprintf('Pre/high load     : %.1f / %.1f W\n', ...
    caseSpec.Pload_Pre_W, caseSpec.Pload_High_W);
fprintf('L / C / fline     : %.3f uH / %.3f uF / %.3f Hz\n', ...
    1e6 * caseSpec.BoostInductance_H, ...
    1e6 * caseSpec.DCBusCapacitance_F, ...
    caseSpec.LineFrequency_Hz);
fprintf('Base/switched R   : %.6f / %.6f ohm\n', ...
    baseResistance_Ohm, switchedResistance_Ohm);
fprintf('KP / KI           : %.10f / %.10f\n', ...
    caseSpec.KP, caseSpec.KI);
fprintf('Fixed IAMP_MAX    : %.3f A\n', ...
    cfg.Controller.FixedIampMax_A);
fprintf('Load-on/off/stop  : %.3f / %.3f / %.3f s\n', ...
    profile.LoadOnTime_s, ...
    profile.LoadOffTime_s, ...
    profile.StopTime_s);
fprintf('Baseline SHA-256  : %s\n', hashBefore);
fprintf('Free disk before  : %.2f GB\n', freeSpaceBeforeRun_GB);
fprintf(['Low-disk logging  : VOUT/IL/VAC/DUTY/IREF ' ...
    'decimation %d/%d/%d/%d/%d\n'], ...
    cfg.Model.LowDiskLoggedDecimation(1), ...
    cfg.Model.LowDiskLoggedDecimation(2), ...
    cfg.Model.LowDiskLoggedDecimation(3), ...
    cfg.Model.LowDiskLoggedDecimation(4), ...
    cfg.Model.LowDiskLoggedDecimation(5));
fprintf('====================================================\n');


%% ============================================================
% APPLY TEMPORARY PARAMETERS AND SIMULATE
%% ============================================================

runTimer = tic;

try
    if cfg.Model.CloseEditorDuringRuns
        set_param(mdl, 'Open', 'off');
        fprintf('Simulink model editor: CLOSED\n');
    end

    disabledScopeCount = disableVisualizationBlocks( ...
        cfg.Model.ScopeBlocks);

    fprintf('Visualization blocks disabled: %d\n', ...
        disabledScopeCount);

    updatedControllerScript = insertControllerParameters( ...
        originalState.ControllerScript, ...
        caseSpec.KP, ...
        caseSpec.KI, ...
        cfg.Controller.FixedIampMax_A);

    controller.Script = updatedControllerScript;

    set_param( ...
        cfg.Model.ACSourceBlock, ...
        'Amplitude', ...
        numericText(sourceAmplitude_Vpeak));

    set_param( ...
        cfg.Model.ACSourceBlock, ...
        'Frequency', ...
        numericText(caseSpec.LineFrequency_Hz));

    set_param( ...
        cfg.Model.BoostInductorBlock, ...
        'Inductance', ...
        numericText(caseSpec.BoostInductance_H));

    set_param( ...
        cfg.Model.DCBusCapacitorBlock, ...
        'Capacitance', ...
        numericText(caseSpec.DCBusCapacitance_F));

    set_param( ...
        cfg.Model.BaseLoadBlock, ...
        'Resistance', ...
        numericText(baseResistance_Ohm));

    set_param( ...
        cfg.Model.SwitchedLoadBlock, ...
        'Resistance', ...
        numericText(switchedResistance_Ohm));

    set_param( ...
        cfg.Model.LoadOnStepBlock, ...
        'Time', numericText(profile.LoadOnTime_s), ...
        'Before', numericText(cfg.Profile.StepBefore), ...
        'After', numericText(cfg.Profile.LoadOnStepAfter));

    set_param( ...
        cfg.Model.LoadOffStepBlock, ...
        'Time', numericText(profile.LoadOffTime_s), ...
        'Before', numericText(cfg.Profile.StepBefore), ...
        'After', numericText(cfg.Profile.LoadOffStepAfter));

    set_param(mdl, 'StopTime', numericText(profile.StopTime_s));
    set_param(mdl, 'SignalLogging', 'on');
    set_param(mdl, 'SignalLoggingName', cfg.Model.SignalLoggingName);
    set_param(mdl, 'ReturnWorkspaceOutputs', 'on');

    configureLowDiskSignalLogging(mdl, cfg);
    disableUnusedModelOutputs(mdl, cfg);

    set_param(mdl, 'SimulationCommand', 'update');

    verifyTemporaryController( ...
        char(controller.Script), ...
        caseSpec.KP, ...
        caseSpec.KI, ...
        cfg.Controller.FixedIampMax_A);

    simOut = sim( ...
        mdl, ...
        'StopTime', numericText(profile.StopTime_s), ...
        'SignalLogging', 'on', ...
        'SignalLoggingName', cfg.Model.SignalLoggingName, ...
        'SaveTime', 'off', ...
        'SaveOutput', 'off', ...
        'SaveState', 'off', ...
        'SaveFinalState', 'off', ...
        'DSMLogging', 'off', ...
        'StreamToWks', 'off', ...
        'ReturnWorkspaceOutputs', 'on');

    metrics = calculatePFCMetrics( ...
        simOut, profile, cfg, caseSpec.LineFrequency_Hz);
    [performanceObjective, objectiveTerms] = ...
        calculatePFCObjective(metrics, cfg);
    [safetyPassed, safetyChecks] = evaluatePFCSafety(metrics, cfg);

    if cfg.Objective.ComputeOnlyForSafeRuns && ~safetyPassed
        objective = cfg.Objective.FailedSimulationPenalty;
    else
        objective = performanceObjective;
    end

    result.SimulationSucceeded = true;
    result.SafetyPassed = safetyPassed;
    result.Objective = objective;
    result.PerformanceObjective = performanceObjective;
    result.Metrics = metrics;
    result.ObjectiveTerms = objectiveTerms;
    result.SafetyChecks = safetyChecks;

catch runError
    result.SimulationSucceeded = false;
    result.SafetyPassed = false;
    result.Objective = cfg.Objective.FailedSimulationPenalty;
    result.PerformanceObjective = NaN;
    result.ErrorIdentifier = string(runError.identifier);
    result.ErrorMessage = string(runError.message);
end

if exist('simOut', 'var')
    clear simOut;
end

result.SDIRepositoryCleared = clearSDIRepository(cfg);
clear repositoryCleanupGuard;

result.ElapsedTime_s = toc(runTimer);


%% ============================================================
% RESTORE MODEL AND VERIFY BASELINE FILE
%% ============================================================

clear cleanupGuard;

hashAfter = calculateFileSHA256(modelFullPath);
result.BaselineSHA256After = string(hashAfter);
result.BaselineFileUnchanged = strcmpi(hashBefore, hashAfter);

if ~result.BaselineFileUnchanged
    error( ...
        'PFCMLSingleCase:BaselineFileChanged', ...
        ['Baseline SHA-256 changed during the run.\n' ...
         'Before: %s\nAfter : %s'], ...
        hashBefore, hashAfter);
end

if bdIsLoaded(mdl)
    result.ModelDirtyAfterRestore = string(get_param(mdl, 'Dirty'));
else
    result.ModelDirtyAfterRestore = "not-loaded";
end


%% ============================================================
% SAVE RESULT ARTIFACTS
%% ============================================================

summaryTable = createSummaryTable(result);
result.SummaryTable = summaryTable;

if caseSpec.SaveArtifacts
    [matFile, csvFile] = saveResultArtifacts( ...
        result, summaryTable, scriptFolder, cfg);

    result.MATFile = string(matFile);
    result.CSVFile = string(csvFile);
end


%% ============================================================
% PRINT FINAL RESULT
%% ============================================================

fprintf('\n');
fprintf('====================================================\n');

if result.SimulationSucceeded
    fprintf('PFC ML - SINGLE SIMULINK CASE COMPLETED\n');
    fprintf('Objective          : %.6f\n', result.Objective);
    fprintf('Performance J      : %.6f\n', ...
        result.PerformanceObjective);
    fprintf('Safety passed      : %d\n', result.SafetyPassed);
    fprintf('Pre/high/post Vout : %.3f / %.3f / %.3f V\n', ...
        result.Metrics.PreLoadMean_V, ...
        result.Metrics.HighLoadMean_V, ...
        result.Metrics.PostLoadMean_V);
    fprintf('Undershoot         : %.3f V\n', ...
        result.Metrics.LoadOnUndershoot_V);
    fprintf('Overshoot          : %.3f V\n', ...
        result.Metrics.LoadOffOvershoot_V);
    fprintf('Settling on/off    : %.4f / %.4f s\n', ...
        result.Metrics.LoadOnSettling_s, ...
        result.Metrics.LoadOffSettling_s);
    fprintf('High-load ripple   : %.3f Vpp\n', ...
        result.Metrics.HighLoadRipple_Vpp);
    fprintf('Global Vout min/max: %.3f / %.3f V\n', ...
        result.Metrics.GlobalVoutMinimum_V, ...
        result.Metrics.GlobalVoutMaximum_V);
    fprintf('IL peak            : %.3f A\n', ...
        result.Metrics.ILPeak_A);
    fprintf('PF / THD           : %.6f / %.3f %%\n', ...
        result.Metrics.PowerFactor, ...
        result.Metrics.THD_Percent);
    fprintf('Input power        : %.3f W\n', ...
        result.Metrics.InputPower_W);
    fprintf('Duty min/max       : %.6f / %.6f\n', ...
        result.Metrics.DutyMinimum, ...
        result.Metrics.DutyMaximum);
    fprintf('Duty saturation    : %.4f %%\n', ...
        100.0 * result.Metrics.DutySaturationFraction);
    fprintf('Iref peak          : %.3f A\n', ...
        result.Metrics.IrefPeak_A);
    fprintf('Iref saturation    : %.4f %%\n', ...
        100.0 * result.Metrics.IrefSaturationFraction);
else
    fprintf('PFC ML - SINGLE SIMULINK CASE FAILED\n');
    fprintf('Error identifier   : %s\n', ...
        char(result.ErrorIdentifier));
    fprintf('Error message      : %s\n', ...
        char(result.ErrorMessage));
end

fprintf('Elapsed time       : %.3f s\n', result.ElapsedTime_s);
fprintf('Baseline unchanged : %d\n', result.BaselineFileUnchanged);
fprintf('Model dirty state  : %s\n', ...
    char(result.ModelDirtyAfterRestore));

if strlength(result.MATFile) > 0
    fprintf('MAT file           : %s\n', char(result.MATFile));
    fprintf('CSV file           : %s\n', char(result.CSVFile));
end

fprintf('====================================================\n\n');

disp(summaryTable);

end


%% ============================================================
% DEFAULT CASE AND INPUT VALIDATION
%% ============================================================

function caseSpec = createDefaultCase(cfg)

caseSpec = struct();
caseSpec.ScenarioID = "STAGE3_NOMINAL_BENCHMARK";
caseSpec.RandomSeed = cfg.Project.RandomSeed;
caseSpec.Vin_RMS = 230.0;
caseSpec.Pload_Pre_W = cfg.Load.NominalPreLoad_W;
caseSpec.Pload_High_W = cfg.Load.NominalHighLoad_W;
caseSpec.BoostInductance_H = cfg.Physical.BoostInductance_H;
caseSpec.DCBusCapacitance_F = cfg.Physical.DCBusCapacitance_F;
caseSpec.LineFrequency_Hz = cfg.Physical.LineFrequency_Hz;
caseSpec.KP = cfg.Controller.BenchmarkKP;
caseSpec.KI = cfg.Controller.BenchmarkKI;
caseSpec.Profile = "Diagnostic";
caseSpec.SaveArtifacts = true;
caseSpec.GainDomain = "Pilot";

end


function caseSpec = completeCaseSpec(caseSpec, cfg)

defaults = createDefaultCase(cfg);
defaultFields = fieldnames(defaults);

for fieldIndex = 1:numel(defaultFields)
    fieldName = defaultFields{fieldIndex};

    if ~isfield(caseSpec, fieldName) || isempty(caseSpec.(fieldName))
        caseSpec.(fieldName) = defaults.(fieldName);
    end
end

caseSpec.ScenarioID = string(caseSpec.ScenarioID);
caseSpec.Profile = string(caseSpec.Profile);
caseSpec.SaveArtifacts = logical(caseSpec.SaveArtifacts);
caseSpec.GainDomain = string(caseSpec.GainDomain);

end


function validateCaseSpec(caseSpec, cfg)

requiredFields = { ...
    'ScenarioID', ...
    'RandomSeed', ...
    'Vin_RMS', ...
    'Pload_Pre_W', ...
    'Pload_High_W', ...
    'BoostInductance_H', ...
    'DCBusCapacitance_F', ...
    'LineFrequency_Hz', ...
    'KP', ...
    'KI', ...
    'Profile', ...
    'SaveArtifacts', ...
    'GainDomain'};

for fieldIndex = 1:numel(requiredFields)
    fieldName = requiredFields{fieldIndex};

    if ~isfield(caseSpec, fieldName)
        error( ...
            'PFCMLSingleCase:MissingCaseField', ...
            'caseSpec is missing the field: %s', ...
            fieldName);
    end
end

numericValues = [ ...
    caseSpec.RandomSeed, ...
    caseSpec.Vin_RMS, ...
    caseSpec.Pload_Pre_W, ...
    caseSpec.Pload_High_W, ...
    caseSpec.BoostInductance_H, ...
    caseSpec.DCBusCapacitance_F, ...
    caseSpec.LineFrequency_Hz, ...
    caseSpec.KP, ...
    caseSpec.KI];

if any(~isfinite(numericValues))
    error( ...
        'PFCMLSingleCase:NonfiniteCaseValue', ...
        'All numeric case values must be finite.');
end

physicalValueTolerance = 1e-12;
frequencyTolerance = 1e-9;

if caseSpec.BoostInductance_H < ...
        cfg.Physical.BoostInductanceRange_H(1) - physicalValueTolerance || ...
        caseSpec.BoostInductance_H > ...
        cfg.Physical.BoostInductanceRange_H(2) + physicalValueTolerance
    error( ...
        'PFCMLSingleCase:InductanceOutOfRange', ...
        'Boost inductance is outside the protected Stage 7 range.');
end

if caseSpec.DCBusCapacitance_F < ...
        cfg.Physical.DCBusCapacitanceRange_F(1) - physicalValueTolerance || ...
        caseSpec.DCBusCapacitance_F > ...
        cfg.Physical.DCBusCapacitanceRange_F(2) + physicalValueTolerance
    error( ...
        'PFCMLSingleCase:CapacitanceOutOfRange', ...
        'DC-bus capacitance is outside the protected Stage 7 range.');
end

if caseSpec.LineFrequency_Hz < ...
        cfg.Physical.LineFrequencyRange_Hz(1) - frequencyTolerance || ...
        caseSpec.LineFrequency_Hz > ...
        cfg.Physical.LineFrequencyRange_Hz(2) + frequencyTolerance
    error( ...
        'PFCMLSingleCase:LineFrequencyOutOfRange', ...
        'Line frequency is outside the protected Stage 7 range.');
end

if caseSpec.Vin_RMS < cfg.Physical.InputVoltageRange_Vrms(1) || ...
        caseSpec.Vin_RMS > cfg.Physical.InputVoltageRange_Vrms(2)
    error( ...
        'PFCMLSingleCase:InputVoltageOutOfRange', ...
        'Vin_RMS must remain inside %.1f-%.1f VAC.', ...
        cfg.Physical.InputVoltageRange_Vrms(1), ...
        cfg.Physical.InputVoltageRange_Vrms(2));
end

if caseSpec.Pload_Pre_W <= 0.0 || ...
        caseSpec.Pload_High_W <= caseSpec.Pload_Pre_W
    error( ...
        'PFCMLSingleCase:InvalidLoadPowers', ...
        'High-load power must be greater than positive pre-load power.');
end

if caseSpec.Pload_High_W > cfg.Physical.RatedPower_W
    error( ...
        'PFCMLSingleCase:RatedPowerExceeded', ...
        'Requested high load exceeds the configured 1.4 kW rating.');
end

if caseSpec.Pload_High_W - caseSpec.Pload_Pre_W < ...
        cfg.Load.MinimumLoadStep_W
    error( ...
        'PFCMLSingleCase:LoadStepTooSmall', ...
        'Requested load step must be at least %.1f W.', ...
        cfg.Load.MinimumLoadStep_W);
end

if caseSpec.KP <= 0.0 || caseSpec.KI <= 0.0
    error( ...
        'PFCMLSingleCase:NonpositiveGain', ...
        'KP and KI must be strictly positive.');
end

if strcmpi(caseSpec.GainDomain, "Pilot")
    allowedKPBounds = cfg.Gains.PilotKPBounds;
    allowedKIBounds = cfg.Gains.PilotKIBounds;
elseif strcmpi(caseSpec.GainDomain, "Expanded")
    allowedKPBounds = cfg.Gains.ExpandedKPBounds;
    allowedKIBounds = cfg.Gains.ExpandedKIBounds;
elseif strcmpi(caseSpec.GainDomain, "OuterProbe")
    allowedKPBounds = cfg.Gains.OuterProbeKPBounds;
    allowedKIBounds = cfg.Gains.OuterProbeKIBounds;
elseif strcmpi(caseSpec.GainDomain, "BoundaryProbe")
    allowedKPBounds = cfg.Gains.BoundaryProbeKPBounds;
    allowedKIBounds = cfg.Gains.BoundaryProbeKIBounds;
else
    error( ...
        'PFCMLSingleCase:UnknownGainDomain', ...
        ['GainDomain must be Pilot, Expanded, OuterProbe, ' ...
         'or BoundaryProbe.']);
end

if caseSpec.KP < allowedKPBounds(1) || ...
        caseSpec.KP > allowedKPBounds(2) || ...
        caseSpec.KI < allowedKIBounds(1) || ...
        caseSpec.KI > allowedKIBounds(2)
    error( ...
        'PFCMLSingleCase:GainOutsideProtectedDomain', ...
        ['Requested gains exceed the %s protected domain. ' ...
         'KP %.4g-%.4g, KI %.4g-%.4g.'], ...
        char(caseSpec.GainDomain), ...
        allowedKPBounds(1), ...
        allowedKPBounds(2), ...
        allowedKIBounds(1), ...
        allowedKIBounds(2));
end

if ~any(strcmpi(caseSpec.Profile, ["Diagnostic", "LongValidation"]))
    error( ...
        'PFCMLSingleCase:UnknownProfile', ...
        'Profile must be Diagnostic or LongValidation.');
end

end


function profile = selectProfile(profileName, cfg)

if strcmpi(profileName, "Diagnostic")
    profile = cfg.Profile.Diagnostic;
elseif strcmpi(profileName, "LongValidation")
    profile = cfg.Profile.LongValidation;
else
    error( ...
        'PFCMLSingleCase:UnknownProfile', ...
        'Unknown simulation profile: %s', ...
        char(profileName));
end

end


%% ============================================================
% MODEL STATE CAPTURE AND RESTORE
%% ============================================================

function controller = findPFCController(mdl)

charts = find(sfroot, '-isa', 'Stateflow.EMChart');
controller = [];

for chartIndex = 1:numel(charts)
    chartPath = char(charts(chartIndex).Path);
    scriptText = char(charts(chartIndex).Script);

    if startsWith(chartPath, [mdl '/']) && ...
            contains(scriptText, 'STM32_PFC_Controller') && ...
            contains(scriptText, 'KP_V') && ...
            contains(scriptText, 'KI_V') && ...
            contains(scriptText, 'IAMP_MAX')
        controller = charts(chartIndex);
        break;
    end
end

if isempty(controller)
    error( ...
        'PFCMLSingleCase:ControllerNotFound', ...
        'STM32_PFC_Controller MATLAB Function block was not found.');
end

end


function state = captureOriginalState(mdl, controller, cfg)

state = struct();
state.ControllerScript = char(controller.Script);
state.ACAmplitude = get_param(cfg.Model.ACSourceBlock, 'Amplitude');
state.ACFrequency = get_param(cfg.Model.ACSourceBlock, 'Frequency');
state.BoostInductance = get_param( ...
    cfg.Model.BoostInductorBlock, 'Inductance');
state.DCBusCapacitance = get_param( ...
    cfg.Model.DCBusCapacitorBlock, 'Capacitance');
state.BaseLoadResistance = get_param( ...
    cfg.Model.BaseLoadBlock, 'Resistance');
state.SwitchedLoadResistance = get_param( ...
    cfg.Model.SwitchedLoadBlock, 'Resistance');

state.LoadOnTime = get_param(cfg.Model.LoadOnStepBlock, 'Time');
state.LoadOnBefore = get_param(cfg.Model.LoadOnStepBlock, 'Before');
state.LoadOnAfter = get_param(cfg.Model.LoadOnStepBlock, 'After');

state.LoadOffTime = get_param(cfg.Model.LoadOffStepBlock, 'Time');
state.LoadOffBefore = get_param(cfg.Model.LoadOffStepBlock, 'Before');
state.LoadOffAfter = get_param(cfg.Model.LoadOffStepBlock, 'After');

state.StopTime = get_param(mdl, 'StopTime');
state.SignalLogging = get_param(mdl, 'SignalLogging');
state.SignalLoggingName = get_param(mdl, 'SignalLoggingName');
state.ReturnWorkspaceOutputs = get_param( ...
    mdl, 'ReturnWorkspaceOutputs');
state.DataLoggingOverride = get_param(mdl, 'DataLoggingOverride');
state.SaveTime = get_param(mdl, 'SaveTime');
state.SaveOutput = get_param(mdl, 'SaveOutput');
state.SaveState = get_param(mdl, 'SaveState');
state.SaveFinalState = get_param(mdl, 'SaveFinalState');
state.DSMLogging = get_param(mdl, 'DSMLogging');
state.StreamToWks = get_param(mdl, 'StreamToWks');

state.ScopeCommented = strings(numel(cfg.Model.ScopeBlocks), 1);

for scopeIndex = 1:numel(cfg.Model.ScopeBlocks)
    scopePath = char(cfg.Model.ScopeBlocks(scopeIndex));
    state.ScopeCommented(scopeIndex) = string( ...
        get_param(scopePath, 'Commented'));
end

end


function restoreOriginalState( ...
    mdl, controller, state, loadedByFunction, cfg)

if ~bdIsLoaded(mdl)
    return;
end

try
    controller.Script = state.ControllerScript;
catch restoreError
    warning('%s', restoreError.message);
end

restoreBlockParameter(cfg.Model.ACSourceBlock, ...
    'Amplitude', state.ACAmplitude);
restoreBlockParameter(cfg.Model.ACSourceBlock, ...
    'Frequency', state.ACFrequency);
restoreBlockParameter(cfg.Model.BoostInductorBlock, ...
    'Inductance', state.BoostInductance);
restoreBlockParameter(cfg.Model.DCBusCapacitorBlock, ...
    'Capacitance', state.DCBusCapacitance);
restoreBlockParameter(cfg.Model.BaseLoadBlock, ...
    'Resistance', state.BaseLoadResistance);
restoreBlockParameter(cfg.Model.SwitchedLoadBlock, ...
    'Resistance', state.SwitchedLoadResistance);

restoreBlockParameter(cfg.Model.LoadOnStepBlock, ...
    'Time', state.LoadOnTime);
restoreBlockParameter(cfg.Model.LoadOnStepBlock, ...
    'Before', state.LoadOnBefore);
restoreBlockParameter(cfg.Model.LoadOnStepBlock, ...
    'After', state.LoadOnAfter);

restoreBlockParameter(cfg.Model.LoadOffStepBlock, ...
    'Time', state.LoadOffTime);
restoreBlockParameter(cfg.Model.LoadOffStepBlock, ...
    'Before', state.LoadOffBefore);
restoreBlockParameter(cfg.Model.LoadOffStepBlock, ...
    'After', state.LoadOffAfter);

restoreBlockParameter(mdl, 'StopTime', state.StopTime);
restoreBlockParameter(mdl, 'SignalLogging', state.SignalLogging);
restoreBlockParameter(mdl, ...
    'SignalLoggingName', state.SignalLoggingName);
restoreBlockParameter(mdl, ...
    'ReturnWorkspaceOutputs', state.ReturnWorkspaceOutputs);
restoreBlockParameter(mdl, ...
    'DataLoggingOverride', state.DataLoggingOverride);
restoreBlockParameter(mdl, 'SaveTime', state.SaveTime);
restoreBlockParameter(mdl, 'SaveOutput', state.SaveOutput);
restoreBlockParameter(mdl, 'SaveState', state.SaveState);
restoreBlockParameter(mdl, 'SaveFinalState', state.SaveFinalState);
restoreBlockParameter(mdl, 'DSMLogging', state.DSMLogging);
restoreBlockParameter(mdl, 'StreamToWks', state.StreamToWks);

for scopeIndex = 1:numel(cfg.Model.ScopeBlocks)
    scopePath = char(cfg.Model.ScopeBlocks(scopeIndex));

    try
        set_param(scopePath, ...
            'Commented', char(state.ScopeCommented(scopeIndex)));
    catch restoreError
        warning('%s', restoreError.message);
    end
end

try
    set_param(mdl, 'Dirty', 'off');
catch restoreError
    warning('%s', restoreError.message);
end

if loadedByFunction
    try
        close_system(mdl, 0);
    catch restoreError
        warning('%s', restoreError.message);
    end
end

end


function restoreBlockParameter(target, parameterName, value)

try
    set_param(target, parameterName, value);
catch restoreError
    warning('%s', restoreError.message);
end

end


function configureLowDiskSignalLogging(mdl, cfg)

if ~cfg.Storage.LowDiskMode
    return;
end

mdlInfo = Simulink.SimulationData.ModelLoggingInfo(mdl);
mdlInfo.LoggingMode = 'OverrideSignals';
mdlInfo = setLogAsSpecifiedInModel(mdlInfo, mdl, false);

signalCount = numel(cfg.Model.LowDiskLoggedSignalNames);

for signalIndex = 1:signalCount
    blockPath = char( ...
        cfg.Model.LowDiskLoggedBlockPaths(signalIndex));
    portIndex = cfg.Model.LowDiskLoggedPortIndices(signalIndex);

    signalInfo = Simulink.SimulationData.SignalLoggingInfo( ...
        blockPath, portIndex);

    loggingInfo = Simulink.SimulationData.LoggingInfo;
    loggingInfo.DataLogging = true;
    loggingInfo.NameMode = false;
    loggingInfo.DecimateData = true;
    loggingInfo.Decimation = ...
        cfg.Model.LowDiskLoggedDecimation(signalIndex);
    loggingInfo.LimitDataPoints = false;

    signalInfo.LoggingInfo = loggingInfo;
    mdlInfo.Signals(signalIndex) = signalInfo;
end

mdlInfo = verifySignalAndModelPaths(mdlInfo);
set_param(mdl, 'DataLoggingOverride', mdlInfo);

end


function disableUnusedModelOutputs(mdl, cfg)

if ~cfg.Storage.DisableUnusedModelOutputs
    return;
end

set_param(mdl, 'SaveTime', 'off');
set_param(mdl, 'SaveOutput', 'off');
set_param(mdl, 'SaveState', 'off');
set_param(mdl, 'SaveFinalState', 'off');
set_param(mdl, 'DSMLogging', 'off');
set_param(mdl, 'StreamToWks', 'off');

end


function disabledCount = disableVisualizationBlocks(scopeBlocks)

disabledCount = 0;

for scopeIndex = 1:numel(scopeBlocks)
    scopePath = char(scopeBlocks(scopeIndex));

    if getSimulinkBlockHandle(scopePath) < 0
        continue;
    end

    try
        close_system(scopePath);
    catch
        % The viewer may already be closed.
    end

    set_param(scopePath, 'Commented', 'on');
    disabledCount = disabledCount + 1;
end

end


%% ============================================================
% CONTROLLER PARAMETER INSERTION AND VERIFICATION
%% ============================================================

function newScript = insertControllerParameters( ...
    originalScript, KP, KI, IAMP_MAX)

newScript = replaceScalarAssignment(originalScript, 'KP_V', KP);
newScript = replaceScalarAssignment(newScript, 'KI_V', KI);
newScript = replaceScalarAssignment(newScript, 'IAMP_MAX', IAMP_MAX);

end


function newScript = replaceScalarAssignment( ...
    originalScript, variableName, value)

pattern = [ ...
    '(?m)^[ \t]*' regexptranslate('escape', variableName) ...
    '[ \t]*=[ \t]*[-+0-9.eE]+[ \t]*;'];

if isempty(regexp(originalScript, pattern, 'once'))
    error( ...
        'PFCMLSingleCase:ControllerAssignmentMissing', ...
        'Controller assignment was not found: %s', ...
        variableName);
end

% Use 17 significant digits so every IEEE-754 double supplied by
% BayesOpt survives the text round trip. The former %.12g formatting
% discarded low-order digits and caused valid points to be rejected by
% verifyTemporaryController before Simulink was started.
replacement = sprintf('%s = %.17g;', variableName, value);
newScript = regexprep(originalScript, pattern, replacement, 'once');

end


function verifyTemporaryController(scriptText, KP, KI, IAMP_MAX)

readKP = readScalarAssignment(scriptText, 'KP_V');
readKI = readScalarAssignment(scriptText, 'KI_V');
readIamp = readScalarAssignment(scriptText, 'IAMP_MAX');

if ~floatingPointValuesMatch(readKP, KP) || ...
        ~floatingPointValuesMatch(readKI, KI) || ...
        ~floatingPointValuesMatch(readIamp, IAMP_MAX)
    error( ...
        'PFCMLSingleCase:ControllerVerificationFailed', ...
        ['Temporary controller values failed in-memory verification. ' ...
         'Requested/read KP=%.17g/%.17g, KI=%.17g/%.17g, ' ...
         'IAMP_MAX=%.17g/%.17g.'], ...
        KP, readKP, KI, readKI, IAMP_MAX, readIamp);
end

end


function matches = floatingPointValuesMatch(actualValue, expectedValue)

% A 17-digit decimal representation should round-trip exactly. Retain a
% small scale-aware tolerance for parser/platform differences instead of a
% fixed absolute tolerance that behaves differently for KP, KI, and amps.
scale = max([1.0, abs(actualValue), abs(expectedValue)]);
tolerance = 64.0 * eps(scale);

matches = ...
    isfinite(actualValue) && ...
    isfinite(expectedValue) && ...
    abs(actualValue - expectedValue) <= tolerance;

end


function value = readScalarAssignment(scriptText, variableName)

pattern = [ ...
    '(?m)^[ \t]*' regexptranslate('escape', variableName) ...
    '[ \t]*=[ \t]*([-+0-9.eE]+)[ \t]*;'];

token = regexp(scriptText, pattern, 'tokens', 'once');

if isempty(token)
    error( ...
        'PFCMLSingleCase:ControllerValueReadFailed', ...
        'Could not read controller value: %s', ...
        variableName);
end

value = str2double(token{1});

if ~isfinite(value)
    error( ...
        'PFCMLSingleCase:ControllerValueNotFinite', ...
        'Controller value is not finite: %s', ...
        variableName);
end

end


%% ============================================================
% METRIC CALCULATION
%% ============================================================

function metrics = calculatePFCMetrics( ...
    simOut, profile, cfg, lineFrequency_Hz)

[tVout, vout] = readLoggedSignal( ...
    simOut, cfg.Model.SignalLoggingName, 'VOUT_MON');

[tIL, iL] = readLoggedSignal( ...
    simOut, cfg.Model.SignalLoggingName, 'IL_RAW');

[tVac, vac] = readLoggedSignal( ...
    simOut, cfg.Model.SignalLoggingName, 'VAC_RAW');

[tDuty, duty] = readLoggedSignal( ...
    simOut, cfg.Model.SignalLoggingName, 'DUTY_MON');

[tIref, iRef] = readLoggedSignal( ...
    simOut, cfg.Model.SignalLoggingName, 'IREF_MON');

fprintf('Logged signal spans: VOUT %.6f-%.6f s | ', ...
    tVout(1), tVout(end));
fprintf('IL %.6f-%.6f s | VAC %.6f-%.6f s\n', ...
    tIL(1), tIL(end), tVac(1), tVac(end));
fprintf('Control signal spans: DUTY %.6f-%.6f s | IREF %.6f-%.6f s\n', ...
    tDuty(1), tDuty(end), tIref(1), tIref(end));

preStart = profile.LoadOnTime_s + ...
    cfg.Profile.Metrics.PreLoadWindow_s(1);
preEnd = profile.LoadOnTime_s + ...
    cfg.Profile.Metrics.PreLoadWindow_s(2);

highStart = profile.LoadOffTime_s + ...
    cfg.Profile.Metrics.LateHighWindow_s(1);
highEnd = profile.LoadOffTime_s + ...
    cfg.Profile.Metrics.LateHighWindow_s(2);

postStart = profile.LoadOffTime_s + ...
    cfg.Profile.Metrics.PostLoadWindow_s(1);
postEnd = min( ...
    profile.LoadOffTime_s + ...
        cfg.Profile.Metrics.PostLoadWindow_s(2), ...
    profile.StopTime_s - 0.02);

settlingEnd = profile.StopTime_s - 0.02;

requiredStart = min([preStart, highStart, postStart]);
requiredEnd = max([ ...
    preEnd, highEnd, postEnd, settlingEnd, ...
    profile.LoadOffTime_s]);

verifySignalSpan(tVout, requiredStart, requiredEnd, 'VOUT_MON');
verifySignalSpan(tIL, requiredStart, requiredEnd, 'IL_RAW');
verifySignalSpan(tVac, requiredStart, requiredEnd, 'VAC_RAW');
verifySignalSpan(tDuty, requiredStart, requiredEnd, 'DUTY_MON');
verifySignalSpan(tIref, requiredStart, requiredEnd, 'IREF_MON');

PreLoadMean_V = windowMean(tVout, vout, preStart, preEnd);
HighLoadMean_V = windowMean(tVout, vout, highStart, highEnd);
PostLoadMean_V = windowMean(tVout, vout, postStart, postEnd);

targetVout = cfg.Physical.TargetVout_V;

SteadyStateError_V = sqrt(mean([ ...
    PreLoadMean_V - targetVout, ...
    HighLoadMean_V - targetVout, ...
    PostLoadMean_V - targetVout].^2));

metricSampleRate_Hz = min( ...
    50e3, cfg.Profile.Metrics.UniformSampleRate_Hz);

envelopeStart = preStart;
envelopeEnd = settlingEnd;

tEnvelope = createUniformTime( ...
    envelopeStart, envelopeEnd, metricSampleRate_Hz);

voutUniform = interp1(tVout, vout, tEnvelope, 'linear');

linePeriod_s = 1.0 / lineFrequency_Hz;
envelopeSamples = max(3, round( ...
    linePeriod_s * metricSampleRate_Hz));

voutEnvelope = movmean( ...
    voutUniform, envelopeSamples, 'Endpoints', 'shrink');

% The centered line-cycle envelope begins to see the next transition
% before its exact timestamp. Stop the load-on assessment half a line
% cycle early so load-off does not corrupt load-on settling.
loadOnEvaluationEnd = ...
    profile.LoadOffTime_s - 0.5 * linePeriod_s;

loadOnMask = ...
    tEnvelope >= profile.LoadOnTime_s & ...
    tEnvelope <= loadOnEvaluationEnd;

loadOffMask = ...
    tEnvelope >= profile.LoadOffTime_s & ...
    tEnvelope <= settlingEnd;

if ~any(loadOnMask) || ~any(loadOffMask)
    error( ...
        'PFCMLSingleCase:TransientWindowEmpty', ...
        'Load-on or load-off metric window is empty.');
end

LoadOnMinimum_V = min(voutEnvelope(loadOnMask));
LoadOffMaximum_V = max(voutEnvelope(loadOffMask));

LoadOnUndershoot_V = max(0.0, targetVout - LoadOnMinimum_V);
LoadOffOvershoot_V = max(0.0, LoadOffMaximum_V - targetVout);

[LoadOnSettling_s, LoadOnSettled] = calculateSettlingTime( ...
    tEnvelope, ...
    voutEnvelope, ...
    profile.LoadOnTime_s, ...
    loadOnEvaluationEnd, ...
    targetVout, ...
    cfg.Profile.Metrics.SettlingBand_V, ...
    cfg.Profile.Metrics.SettlingHold_s);

[LoadOffSettling_s, LoadOffSettled] = calculateSettlingTime( ...
    tEnvelope, ...
    voutEnvelope, ...
    profile.LoadOffTime_s, ...
    settlingEnd, ...
    targetVout, ...
    cfg.Profile.Metrics.SettlingBand_V, ...
    cfg.Profile.Metrics.SettlingHold_s);

loadOnMAEEnd = min( ...
    profile.LoadOnTime_s + 0.20, ...
    profile.LoadOffTime_s);

loadOffMAEEnd = min( ...
    profile.LoadOffTime_s + 0.30, ...
    settlingEnd);

LoadOnMAE_V = windowMeanAbsoluteError( ...
    tEnvelope, voutEnvelope, ...
    profile.LoadOnTime_s, loadOnMAEEnd, targetVout);

LoadOffMAE_V = windowMeanAbsoluteError( ...
    tEnvelope, voutEnvelope, ...
    profile.LoadOffTime_s, loadOffMAEEnd, targetVout);

HighLoadRipple_Vpp = windowPeakToPeak( ...
    tVout, vout, highStart, highEnd);

analysisMaskVout = ...
    tVout >= preStart & tVout <= settlingEnd;

analysisMaskIL = ...
    tIL >= preStart & tIL <= settlingEnd;

GlobalVoutMinimum_V = min(vout(analysisMaskVout));
GlobalVoutMaximum_V = max(vout(analysisMaskVout));
ILPeak_A = max(abs(iL(analysisMaskIL)));

analysisMaskDuty = ...
    tDuty >= preStart & tDuty <= settlingEnd;
analysisMaskIref = ...
    tIref >= preStart & tIref <= settlingEnd;
highMaskDuty = ...
    tDuty >= profile.LoadOnTime_s & ...
    tDuty <= profile.LoadOffTime_s;
highMaskIref = ...
    tIref >= profile.LoadOnTime_s & ...
    tIref <= profile.LoadOffTime_s;

if ~any(analysisMaskDuty) || ~any(analysisMaskIref) || ...
        ~any(highMaskDuty) || ~any(highMaskIref)
    error( ...
        'PFCMLSingleCase:ControlDiagnosticWindowEmpty', ...
        'DUTY_MON or IREF_MON diagnostic window is empty.');
end

dutyAnalysis = duty(analysisMaskDuty);
iRefAnalysis = iRef(analysisMaskIref);
dutyHigh = duty(highMaskDuty);
iRefHigh = iRef(highMaskIref);

DutyMinimum = min(dutyAnalysis);
DutyMaximum = max(dutyAnalysis);
DutyMeanHigh = mean(dutyHigh);
DutySaturationFraction = mean( ...
    dutyHigh >= cfg.Stage6B.DutySaturationThresholdFraction * ...
        cfg.Controller.DutyMaximum);
DutyStepRMS = calculateStepRMS(dutyHigh);

IrefPeak_A = max(abs(iRefAnalysis));
IrefMeanAbsHigh_A = mean(abs(iRefHigh));
IrefSaturationFraction = mean( ...
    abs(iRefHigh) >= cfg.Stage6B.IrefSaturationThresholdFraction * ...
        cfg.Controller.FixedIampMax_A);
IrefStepRMS_A = calculateStepRMS(iRefHigh);

powerQualityDuration_s = ...
    cfg.Profile.Metrics.LineCyclesForPowerQuality / ...
    lineFrequency_Hz;

powerQualityEnd_s = profile.LoadOffTime_s;
powerQualityStart_s = ...
    powerQualityEnd_s - powerQualityDuration_s;

[PowerFactor, THD_Percent, InputPower_W, ...
    VacRMS_V, IacRMS_A] = calculatePowerQuality( ...
        tVac, vac, tIL, iL, ...
        powerQualityStart_s, ...
        powerQualityEnd_s, cfg, lineFrequency_Hz);

metricVector = [ ...
    PreLoadMean_V, ...
    HighLoadMean_V, ...
    PostLoadMean_V, ...
    SteadyStateError_V, ...
    LoadOnMinimum_V, ...
    LoadOnUndershoot_V, ...
    LoadOffMaximum_V, ...
    LoadOffOvershoot_V, ...
    LoadOnSettling_s, ...
    LoadOffSettling_s, ...
    LoadOnMAE_V, ...
    LoadOffMAE_V, ...
    HighLoadRipple_Vpp, ...
    GlobalVoutMinimum_V, ...
    GlobalVoutMaximum_V, ...
    ILPeak_A, ...
    PowerFactor, ...
    THD_Percent, ...
    InputPower_W, ...
    VacRMS_V, ...
    IacRMS_A, ...
    DutyMinimum, ...
    DutyMaximum, ...
    DutyMeanHigh, ...
    DutySaturationFraction, ...
    DutyStepRMS, ...
    IrefPeak_A, ...
    IrefMeanAbsHigh_A, ...
    IrefSaturationFraction, ...
    IrefStepRMS_A];

if any(~isfinite(metricVector))
    error( ...
        'PFCMLSingleCase:NonfiniteMetric', ...
        'At least one calculated metric is not finite.');
end

metrics = struct();
metrics.PreLoadMean_V = PreLoadMean_V;
metrics.HighLoadMean_V = HighLoadMean_V;
metrics.PostLoadMean_V = PostLoadMean_V;
metrics.SteadyStateError_V = SteadyStateError_V;
metrics.LoadOnMinimum_V = LoadOnMinimum_V;
metrics.LoadOnUndershoot_V = LoadOnUndershoot_V;
metrics.LoadOffMaximum_V = LoadOffMaximum_V;
metrics.LoadOffOvershoot_V = LoadOffOvershoot_V;
metrics.LoadOnSettling_s = LoadOnSettling_s;
metrics.LoadOffSettling_s = LoadOffSettling_s;
metrics.LoadOnSettled = LoadOnSettled;
metrics.LoadOffSettled = LoadOffSettled;
metrics.LoadOnMAE_V = LoadOnMAE_V;
metrics.LoadOffMAE_V = LoadOffMAE_V;
metrics.HighLoadRipple_Vpp = HighLoadRipple_Vpp;
metrics.GlobalVoutMinimum_V = GlobalVoutMinimum_V;
metrics.GlobalVoutMaximum_V = GlobalVoutMaximum_V;
metrics.ILPeak_A = ILPeak_A;
metrics.PowerFactor = PowerFactor;
metrics.THD_Percent = THD_Percent;
metrics.InputPower_W = InputPower_W;
metrics.VacRMS_V = VacRMS_V;
metrics.IacRMS_A = IacRMS_A;
metrics.DutyMinimum = DutyMinimum;
metrics.DutyMaximum = DutyMaximum;
metrics.DutyMeanHigh = DutyMeanHigh;
metrics.DutySaturationFraction = DutySaturationFraction;
metrics.DutyStepRMS = DutyStepRMS;
metrics.IrefPeak_A = IrefPeak_A;
metrics.IrefMeanAbsHigh_A = IrefMeanAbsHigh_A;
metrics.IrefSaturationFraction = IrefSaturationFraction;
metrics.IrefStepRMS_A = IrefStepRMS_A;

end


function value = calculateStepRMS(data)

data = double(data(:));

if numel(data) < 2
    value = 0.0;
else
    value = sqrt(mean(diff(data).^2));
end

end


function [time, data] = readLoggedSignal( ...
    simOut, loggingName, signalName)

try
    logsout = simOut.get(loggingName);
catch
    logsout = [];
end

if isempty(logsout)
    error( ...
        'PFCMLSingleCase:LogsoutMissing', ...
        'Simulation output does not contain %s.', ...
        loggingName);
end

try
    element = logsout.getElement(signalName);
catch readError
    error( ...
        'PFCMLSingleCase:LoggedSignalMissing', ...
        'Logged signal %s could not be read: %s', ...
        signalName, readError.message);
end

values = element.Values;

if isa(values, 'timeseries')
    time = double(values.Time(:));
    data = squeeze(double(values.Data));
elseif istimetable(values)
    time = seconds(values.Properties.RowTimes - ...
        values.Properties.RowTimes(1));
    data = squeeze(double(values.Variables));
else
    error( ...
        'PFCMLSingleCase:UnsupportedLoggedSignalType', ...
        'Signal %s uses unsupported type: %s', ...
        signalName, class(values));
end

data = data(:);

if numel(time) ~= numel(data)
    error( ...
        'PFCMLSingleCase:LoggedSignalSizeMismatch', ...
        'Time and data lengths differ for %s.', ...
        signalName);
end

valid = isfinite(time) & isfinite(data);

if ~all(valid)
    time = time(valid);
    data = data(valid);
end

if ~issorted(time, 'strictascend')
    [time, uniqueIndices] = unique(time, 'sorted');
    data = data(uniqueIndices);
end

if numel(time) < 2
    error( ...
        'PFCMLSingleCase:InvalidLoggedTime', ...
        'Signal %s does not have a valid increasing time vector.', ...
        signalName);
end

end


function verifySignalSpan(time, requiredStart, requiredEnd, signalName)

tolerance = 1e-9;

if time(1) > requiredStart + tolerance || ...
        time(end) < requiredEnd - tolerance
    error( ...
        'PFCMLSingleCase:SignalSpanTooShort', ...
        ['%s spans %.6f-%.6f s but %.6f-%.6f s is required.'], ...
        signalName, time(1), time(end), requiredStart, requiredEnd);
end

end


function value = windowMean(time, data, startTime, endTime)

[windowTime, windowData] = cropSignal( ...
    time, data, startTime, endTime);

duration = windowTime(end) - windowTime(1);

if duration <= 0.0
    error( ...
        'PFCMLSingleCase:InvalidMeanWindow', ...
        'Mean window duration must be positive.');
end

value = trapz(windowTime, windowData) / duration;

end


function value = windowPeakToPeak(time, data, startTime, endTime)

[~, windowData] = cropSignal(time, data, startTime, endTime);
value = max(windowData) - min(windowData);

end


function value = windowMeanAbsoluteError( ...
    time, data, startTime, endTime, target)

[windowTime, windowData] = cropSignal( ...
    time, data, startTime, endTime);

duration = windowTime(end) - windowTime(1);

if duration <= 0.0
    error( ...
        'PFCMLSingleCase:InvalidMAEWindow', ...
        'MAE window duration must be positive.');
end

value = trapz( ...
    windowTime, abs(windowData - target)) / duration;

end


function [croppedTime, croppedData] = cropSignal( ...
    time, data, startTime, endTime)

mask = time >= startTime & time <= endTime;

if nnz(mask) < 2
    error( ...
        'PFCMLSingleCase:SignalWindowEmpty', ...
        'Signal window %.6f-%.6f s has insufficient samples.', ...
        startTime, endTime);
end

croppedTime = time(mask);
croppedData = data(mask);

end


function time = createUniformTime(startTime, endTime, sampleRate)

sampleCount = round((endTime - startTime) * sampleRate) + 1;

if sampleCount < 2
    error( ...
        'PFCMLSingleCase:UniformTimeTooShort', ...
        'Uniform metric time vector is too short.');
end

time = linspace(startTime, endTime, sampleCount).';

end


function [settlingTime, settled] = calculateSettlingTime( ...
    time, signal, transitionTime, windowEnd, ...
    target, band, holdTime)

mask = time >= transitionTime & time <= windowEnd;
localTime = time(mask);
localSignal = signal(mask);

if numel(localTime) < 2
    error( ...
        'PFCMLSingleCase:SettlingWindowEmpty', ...
        'Settling window has insufficient samples.');
end

insideBand = abs(localSignal - target) <= band;
settled = false;
settlingTime = windowEnd - transitionTime;

for sampleIndex = 1:numel(localTime)
    holdEnd = localTime(sampleIndex) + holdTime;

    if holdEnd > windowEnd
        break;
    end

    holdMask = ...
        localTime >= localTime(sampleIndex) & ...
        localTime <= holdEnd;

    remainingMask = localTime >= localTime(sampleIndex);

    if all(insideBand(holdMask)) && all(insideBand(remainingMask))
        settlingTime = localTime(sampleIndex) - transitionTime;
        settled = true;
        break;
    end
end

end


function [PF, THD_Percent, InputPower_W, ...
    VacRMS_V, IacRMS_A] = calculatePowerQuality( ...
        tVac, vac, tIL, iL, startTime, endTime, cfg, ...
        lineFrequency_Hz)

verifySignalSpan(tVac, startTime, endTime, 'VAC_RAW');
verifySignalSpan(tIL, startTime, endTime, 'IL_RAW');

sampleRate = cfg.Profile.Metrics.UniformSampleRate_Hz;
time = createUniformTime(startTime, endTime, sampleRate);

vacUniform = interp1(tVac, vac, time, 'linear');
iRectified = interp1(tIL, abs(iL), time, 'linear');

if min(vacUniform) >= -1.0
    error( ...
        'PFCMLSingleCase:VACPolarityInvalid', ...
        'VAC_RAW does not contain the negative AC half-cycle.');
end

iacUniform = iRectified .* sign(vacUniform);
time = time - time(1);
duration = time(end) - time(1);

VacRMS_V = sqrt(trapz(time, vacUniform.^2) / duration);
IacRMS_A = sqrt(trapz(time, iacUniform.^2) / duration);
InputPower_W = trapz( ...
    time, vacUniform .* iacUniform) / duration;

if VacRMS_V <= 1e-9 || IacRMS_A <= 1e-9
    error( ...
        'PFCMLSingleCase:PowerQualityRMSInvalid', ...
        'Input voltage or current RMS is too close to zero.');
end

PF = abs(InputPower_W) / (VacRMS_V * IacRMS_A);
PF = min(max(PF, 0.0), 1.0);

maximumHarmonic = cfg.Profile.Metrics.THDMaximumHarmonic;
harmonicRMS = zeros(maximumHarmonic, 1);

for harmonic = 1:maximumHarmonic
    omega = 2.0 * pi * harmonic * ...
        lineFrequency_Hz;

    cosineCoefficient = (2.0 / duration) * trapz( ...
        time, iacUniform .* cos(omega * time));

    sineCoefficient = (2.0 / duration) * trapz( ...
        time, iacUniform .* sin(omega * time));

    harmonicPeak = hypot(cosineCoefficient, sineCoefficient);
    harmonicRMS(harmonic) = harmonicPeak / sqrt(2.0);
end

fundamentalRMS = harmonicRMS(1);

if fundamentalRMS <= 1e-9
    error( ...
        'PFCMLSingleCase:FundamentalCurrentInvalid', ...
        'Fundamental input-current component is too close to zero.');
end

THD_Percent = 100.0 * sqrt( ...
    sum(harmonicRMS(2:end).^2)) / fundamentalRMS;

end


%% ============================================================
% OBJECTIVE AND SAFETY
%% ============================================================

function [objective, terms] = calculatePFCObjective(metrics, cfg)

normalization = cfg.Objective.Normalization;

terms = struct();
terms.SteadyError = ...
    metrics.SteadyStateError_V / ...
    normalization.SteadyError_V;

terms.LoadOnUndershoot = ...
    metrics.LoadOnUndershoot_V / ...
    normalization.LoadOnUndershoot_V;

terms.LoadOffOvershoot = ...
    metrics.LoadOffOvershoot_V / ...
    normalization.LoadOffOvershoot_V;

terms.SettlingTime = ...
    (metrics.LoadOnSettling_s + metrics.LoadOffSettling_s) / ...
    normalization.SettlingTime_s;

terms.TransientMAE = ...
    0.5 * (metrics.LoadOnMAE_V + metrics.LoadOffMAE_V) / ...
    normalization.TransientMAE_V;

terms.HighLoadRipple = ...
    metrics.HighLoadRipple_Vpp / ...
    normalization.HighLoadRipple_Vpp;

terms.THD = ...
    metrics.THD_Percent / ...
    normalization.THD_Percent;

terms.PowerFactorError = ...
    (1.0 - metrics.PowerFactor) / ...
    normalization.PowerFactorError;

termVector = [ ...
    terms.SteadyError; ...
    terms.LoadOnUndershoot; ...
    terms.LoadOffOvershoot; ...
    terms.SettlingTime; ...
    terms.TransientMAE; ...
    terms.HighLoadRipple; ...
    terms.THD; ...
    terms.PowerFactorError];

objective = sum(cfg.Objective.Weights .* termVector.^2);

if ~isfinite(objective)
    error( ...
        'PFCMLSingleCase:ObjectiveNotFinite', ...
        'Calculated objective is not finite.');
end

end


function [passed, checks] = evaluatePFCSafety(metrics, cfg)

checks = struct();
metricCells = struct2cell(metrics);
metricValues = cellfun(@double, metricCells);
checks.FiniteMetrics = all(isfinite(metricValues));
checks.LateHighVout = ...
    metrics.HighLoadMean_V >= ...
        cfg.Safety.LateHighLoadVoutRange_V(1) && ...
    metrics.HighLoadMean_V <= ...
        cfg.Safety.LateHighLoadVoutRange_V(2);

checks.GlobalVoutMinimum = ...
    metrics.GlobalVoutMinimum_V >= ...
        cfg.Safety.GlobalVoutMinimum_V;

checks.GlobalVoutMaximum = ...
    metrics.GlobalVoutMaximum_V <= ...
        cfg.Safety.GlobalVoutMaximum_V;

checks.InductorPeak = ...
    metrics.ILPeak_A <= cfg.Safety.InductorPeakMaximum_A;

checks.PowerFactor = ...
    metrics.PowerFactor >= cfg.Safety.PowerFactorMinimum;

checks.THD = ...
    metrics.THD_Percent <= cfg.Safety.THDMaximum_Percent;

checks.DutyCommandRange = ...
    metrics.DutyMinimum >= -cfg.Safety.DutyCommandTolerance && ...
    metrics.DutyMaximum <= ...
        cfg.Controller.DutyMaximum + cfg.Safety.DutyCommandTolerance;

checks.IrefCommandLimit = ...
    metrics.IrefPeak_A <= ...
        cfg.Controller.FixedIampMax_A + ...
        cfg.Safety.IrefCommandTolerance_A;

passed = all(cell2mat(struct2cell(checks)));

end


%% ============================================================
% RESULT CREATION, TABLE, AND FILES
%% ============================================================

function result = createEmptyResult( ...
    caseSpec, cfg, sourceAmplitude, baseResistance, ...
    switchedResistance, profile, hashBefore)

result = struct();
result.ConfigVersion = string(cfg.Project.ConfigVersion);
result.ScenarioID = caseSpec.ScenarioID;
result.RandomSeed = caseSpec.RandomSeed;
result.Profile = caseSpec.Profile;
result.GainDomain = caseSpec.GainDomain;
result.Vin_RMS = caseSpec.Vin_RMS;
result.SourceAmplitude_Vpeak = sourceAmplitude;
result.Pload_Pre_W = caseSpec.Pload_Pre_W;
result.Pload_High_W = caseSpec.Pload_High_W;
result.BoostInductance_H = caseSpec.BoostInductance_H;
result.DCBusCapacitance_F = caseSpec.DCBusCapacitance_F;
result.LineFrequency_Hz = caseSpec.LineFrequency_Hz;
result.DeltaP_W = caseSpec.Pload_High_W - caseSpec.Pload_Pre_W;
result.BaseResistance_Ohm = baseResistance;
result.SwitchedResistance_Ohm = switchedResistance;
result.KP = caseSpec.KP;
result.KI = caseSpec.KI;
result.IAMP_MAX_A = cfg.Controller.FixedIampMax_A;
result.LoadOnTime_s = profile.LoadOnTime_s;
result.LoadOffTime_s = profile.LoadOffTime_s;
result.StopTime_s = profile.StopTime_s;
result.SimulationSucceeded = false;
result.SafetyPassed = false;
result.Objective = cfg.Objective.FailedSimulationPenalty;
result.PerformanceObjective = NaN;
result.Metrics = struct();
result.ObjectiveTerms = struct();
result.SafetyChecks = struct();
result.ElapsedTime_s = NaN;
result.ErrorIdentifier = "";
result.ErrorMessage = "";
result.BaselineSHA256Before = string(hashBefore);
result.BaselineSHA256After = "";
result.BaselineFileUnchanged = false;
result.ModelDirtyAfterRestore = "unknown";
result.SDIRepositoryCleared = false;
result.MATFile = "";
result.CSVFile = "";

end


function summary = createSummaryTable(result)

if result.SimulationSucceeded
    m = result.Metrics;
else
    m = createNaNMetrics();
end

summary = table( ...
    result.ScenarioID, ...
    result.Vin_RMS, ...
    result.Pload_Pre_W, ...
    result.Pload_High_W, ...
    1e6 * result.BoostInductance_H, ...
    1e6 * result.DCBusCapacitance_F, ...
    result.LineFrequency_Hz, ...
    result.KP, ...
    result.KI, ...
    result.IAMP_MAX_A, ...
    result.SimulationSucceeded, ...
    result.SafetyPassed, ...
    result.Objective, ...
    result.PerformanceObjective, ...
    m.PreLoadMean_V, ...
    m.HighLoadMean_V, ...
    m.PostLoadMean_V, ...
    m.SteadyStateError_V, ...
    m.LoadOnUndershoot_V, ...
    m.LoadOffOvershoot_V, ...
    m.LoadOnSettling_s, ...
    m.LoadOffSettling_s, ...
    m.HighLoadRipple_Vpp, ...
    m.GlobalVoutMinimum_V, ...
    m.GlobalVoutMaximum_V, ...
    m.ILPeak_A, ...
    m.PowerFactor, ...
    m.THD_Percent, ...
    m.InputPower_W, ...
    m.DutyMinimum, ...
    m.DutyMaximum, ...
    m.DutyMeanHigh, ...
    m.DutySaturationFraction, ...
    m.DutyStepRMS, ...
    m.IrefPeak_A, ...
    m.IrefMeanAbsHigh_A, ...
    m.IrefSaturationFraction, ...
    m.IrefStepRMS_A, ...
    result.ElapsedTime_s, ...
    result.BaselineFileUnchanged, ...
    result.ErrorIdentifier, ...
    result.ErrorMessage, ...
    'VariableNames', { ...
        'ScenarioID', ...
        'Vin_RMS', ...
        'Pload_Pre_W', ...
        'Pload_High_W', ...
        'BoostInductance_uH', ...
        'DCBusCapacitance_uF', ...
        'LineFrequency_Hz', ...
        'KP', ...
        'KI', ...
        'IAMP_MAX_A', ...
        'SimulationSucceeded', ...
        'SafetyPassed', ...
        'Objective', ...
        'PerformanceObjective', ...
        'PreLoadMean_V', ...
        'HighLoadMean_V', ...
        'PostLoadMean_V', ...
        'SteadyStateError_V', ...
        'LoadOnUndershoot_V', ...
        'LoadOffOvershoot_V', ...
        'LoadOnSettling_s', ...
        'LoadOffSettling_s', ...
        'HighLoadRipple_Vpp', ...
        'GlobalVoutMinimum_V', ...
        'GlobalVoutMaximum_V', ...
        'ILPeak_A', ...
        'PowerFactor', ...
        'THD_Percent', ...
        'InputPower_W', ...
        'DutyMinimum', ...
        'DutyMaximum', ...
        'DutyMeanHigh', ...
        'DutySaturationFraction', ...
        'DutyStepRMS', ...
        'IrefPeak_A', ...
        'IrefMeanAbsHigh_A', ...
        'IrefSaturationFraction', ...
        'IrefStepRMS_A', ...
        'ElapsedTime_s', ...
        'BaselineFileUnchanged', ...
        'ErrorIdentifier', ...
        'ErrorMessage'});

end


function metrics = createNaNMetrics()

metrics = struct();
metrics.PreLoadMean_V = NaN;
metrics.HighLoadMean_V = NaN;
metrics.PostLoadMean_V = NaN;
metrics.SteadyStateError_V = NaN;
metrics.LoadOnUndershoot_V = NaN;
metrics.LoadOffOvershoot_V = NaN;
metrics.LoadOnSettling_s = NaN;
metrics.LoadOffSettling_s = NaN;
metrics.HighLoadRipple_Vpp = NaN;
metrics.GlobalVoutMinimum_V = NaN;
metrics.GlobalVoutMaximum_V = NaN;
metrics.ILPeak_A = NaN;
metrics.PowerFactor = NaN;
metrics.THD_Percent = NaN;
metrics.InputPower_W = NaN;
metrics.DutyMinimum = NaN;
metrics.DutyMaximum = NaN;
metrics.DutyMeanHigh = NaN;
metrics.DutySaturationFraction = NaN;
metrics.DutyStepRMS = NaN;
metrics.IrefPeak_A = NaN;
metrics.IrefMeanAbsHigh_A = NaN;
metrics.IrefSaturationFraction = NaN;
metrics.IrefStepRMS_A = NaN;

end


function [matFile, csvFile] = saveResultArtifacts( ...
    result, summaryTable, scriptFolder, cfg)

outputFolder = fullfile(scriptFolder, cfg.Files.RootOutputFolder);

if ~isfolder(outputFolder)
    mkdir(outputFolder);
end

timestamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
safeScenarioID = regexprep( ...
    char(result.ScenarioID), '[^A-Za-z0-9_-]', '_');

baseName = sprintf( ...
    'pfc_ml_stage3_%s_%s', safeScenarioID, timestamp);

matFile = fullfile(outputFolder, [baseName '.mat']);
csvFile = fullfile(outputFolder, [baseName '.csv']);

save(matFile, 'result', 'summaryTable');
writetable(summaryTable, csvFile);

end


%% ============================================================
% SMALL UTILITIES
%% ============================================================

function freeSpace_GB = verifyFreeDiskSpace(folderPath, cfg)

folderObject = java.io.File(folderPath);
freeSpace_GB = double(folderObject.getUsableSpace()) / (1024.0^3);

if ~isfinite(freeSpace_GB) || freeSpace_GB < 0.0
    error( ...
        'PFCMLSingleCase:DiskSpaceReadFailed', ...
        'Could not determine usable disk space for %s.', ...
        folderPath);
end

if freeSpace_GB < cfg.Storage.MinimumFreeSpaceBeforeRun_GB
    error( ...
        'PFCMLSingleCase:InsufficientDiskSpace', ...
        ['Only %.2f GB is free. At least %.2f GB is required before ' ...
         'starting another Simulink run.'], ...
        freeSpace_GB, cfg.Storage.MinimumFreeSpaceBeforeRun_GB);
end

if freeSpace_GB < cfg.Storage.WarnBelowFreeSpace_GB
    warning( ...
        'PFCMLSingleCase:LowDiskSpace', ...
        '%s', ...
        sprintf( ...
            ['Free disk space is %.2f GB. The run may continue, but ' ...
             'disk usage should be monitored.'], ...
            freeSpace_GB));
end

end


function cleared = clearSDIRepository(cfg)

cleared = false;

if ~cfg.Storage.ClearSDIRepositoryAfterEachRun && ...
        ~cfg.Storage.ClearSDIRepositoryBeforeEachRun
    return;
end

try
    Simulink.sdi.clear(Export=false);
    cleared = true;
catch cleanupError
    warning( ...
        'PFCMLSingleCase:SDICleanupFailed', ...
        '%s', cleanupError.message);
end

end


function clearSDIRepositoryBestEffort(cfg)

try
    if cfg.Storage.ClearSDIRepositoryAfterEachRun
        Simulink.sdi.clear(Export=false);
    end
catch
    % Never hide the original simulation error during onCleanup.
end

end


function text = numericText(value)

text = sprintf('%.15g', value);

end


function hashText = calculateFileSHA256(filePath)

fileIdentifier = fopen(filePath, 'rb');

if fileIdentifier < 0
    error( ...
        'PFCMLSingleCase:FileReadFailed', ...
        'Could not open file for SHA-256: %s', ...
        filePath);
end

fileCleanup = onCleanup(@() fclose(fileIdentifier));
fileBytes = fread(fileIdentifier, Inf, '*uint8');
clear fileCleanup;

digest = java.security.MessageDigest.getInstance('SHA-256');
digest.update(typecast(fileBytes(:), 'int8'));
rawHash = typecast(digest.digest(), 'uint8');
hashText = lower(reshape(dec2hex(rawHash, 2).', 1, []));

end
