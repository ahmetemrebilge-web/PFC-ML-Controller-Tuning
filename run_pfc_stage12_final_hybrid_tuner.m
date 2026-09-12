function result = run_pfc_stage12_final_hybrid_tuner(inputSpec)
%RUN_PFC_STAGE12_FINAL_HYBRID_TUNER Final selective ML deployment workflow.
%
% Policy:
%   1) Load the clean Stage 11 PASS artifact or its real-data Stage 12 update.
%   2) Let ML recommend KP/KI only when every uncertainty gate passes.
%   3) Verify an ML recommendation with one protected real Simulink run.
%   4) ABSTAIN or failed verification invokes a fixed four-point real
%      Simulink fallback and returns the best measured feasible point.
%   5) Update the models only from real measured POLICY rows. Stage 11
%      REFERENCE_ONLY rows never train the deployment model.
%
% Set VerifyInSimulink=false for inference only. In that mode UpdateModel
% must also be false because no real label is acquired.
%
% Revision: 2.1.0
% MATLAB release: R2025a


%% ============================================================
% CONFIGURATION AND DEPENDENCY GATES
%% ============================================================

cfg = pfc_ml_config();

if string(cfg.Project.ConfigVersion) ~= "1.6.0"
    error( ...
        'PFCMLStage12:WrongConfigRevision', ...
        'Stage 12 requires pfc_ml_config version 1.6.0.');
end

runnerPath = which('run_single_pfc_case');

if isempty(runnerPath) || ...
        ~contains(fileread(runnerPath), 'Runner revision: 1.6.0')
    error( ...
        'PFCMLStage12:WrongRunnerRevision', ...
        'Stage 12 requires run_single_pfc_case revision 1.6.0.');
end

requiredFunctions = string({'fitcensemble'; 'fitrgp'; 'templateTree'});

for functionIndex = 1:numel(requiredFunctions)
    if isempty(which(char(requiredFunctions(functionIndex))))
        error( ...
            'PFCMLStage12:RequiredFunctionMissing', ...
            'Required ML function missing: %s', ...
            char(requiredFunctions(functionIndex)));
    end
end

if nargin < 1 || isempty(inputSpec)
    inputSpec = struct();
end

inputSpec = completeDeploymentOptions(inputSpec);
prediction = predict_pfc_stage12_gains(inputSpec);
inputSpec = prediction.InputSpec;

if ~inputSpec.VerifyInSimulink && inputSpec.UpdateModel
    error( ...
        'PFCMLStage12:UpdateWithoutRealLabelForbidden', ...
        ['UpdateModel cannot be true when VerifyInSimulink is false. ' ...
         'The project never learns from predicted or synthetic labels.']);
end


%% ============================================================
% LOAD FINAL BENCHMARK AND OPTIONAL DEVELOPMENT DATA
%% ============================================================

scriptFolder = fileparts(mfilename('fullpath'));
stage11Output = loadStage11Output(scriptFolder);
[legacyDataset, targetedDataset] = loadDevelopmentData( ...
    scriptFolder, cfg, inputSpec.UpdateModel);

outputFolder = fullfile( ...
    scriptFolder, 'pfc_ml_outputs_stage12_final_v210');

if ~isfolder(outputFolder)
    mkdir(outputFolder);
end

onlineMATFile = fullfile( ...
    outputFolder, 'pfc_ml_stage12_online_real_data.mat');
onlineCSVFile = fullfile( ...
    outputFolder, 'pfc_ml_stage12_online_real_data.csv');
onlineModelFile = fullfile( ...
    outputFolder, 'pfc_ml_stage12_online_models.mat');
decisionMATFile = fullfile( ...
    outputFolder, 'pfc_ml_stage12_latest_decision.mat');
traceCSVFile = fullfile( ...
    outputFolder, 'pfc_ml_stage12_latest_trace.csv');
predictionCSVFile = fullfile( ...
    outputFolder, 'pfc_ml_stage12_latest_prediction.csv');

onlineDataset = table();

if isfile(onlineMATFile)
    loadedOnline = load(onlineMATFile, 'onlineDataset');

    if isfield(loadedOnline, 'onlineDataset')
        onlineDataset = loadedOnline.onlineDataset;
        validateOnlineDataset(onlineDataset);
    end
end


%% ============================================================
% PREDICTION-ONLY EXIT
%% ============================================================

if ~inputSpec.VerifyInSimulink
    result = createPredictionOnlyResult(prediction, onlineDataset);
    save(decisionMATFile, 'result', '-v7.3');
    writetable(prediction.ResultTable, predictionCSVFile);

    fprintf('\n');
    fprintf('====================================================\n');
    fprintf('PFC ML STAGE 12 - PREDICTION-ONLY CALL COMPLETED\n');
    fprintf('====================================================\n');
    fprintf('Decision          : %s\n', char(prediction.Decision));
    fprintf('Simulink runs     : 0\n');
    fprintf('Real labels added : 0\n');
    fprintf('Model updated     : 0\n');
    fprintf('Verified output   : 0\n');
    fprintf('Synthetic outputs : 0\n');
    fprintf('Prediction CSV    : %s\n', predictionCSVFile);
    fprintf('====================================================\n');
    return;
end


%% ============================================================
% REAL-SIMULINK POLICY
%% ============================================================

trace = table();
candidateSummaries = table();
selectedSummary = table();
selectedSource = "";
newRealSimulations = 0;
measuredCacheUses = 0;
newOnlineRows = 0;

fprintf('\n');
fprintf('====================================================\n');
fprintf('PFC ML STAGE 12 - FINAL HYBRID TUNER\n');
fprintf('====================================================\n');
fprintf('Scenario          : %s\n', char(inputSpec.ScenarioID));
fprintf('Initial decision  : %s\n', char(prediction.Decision));
fprintf('Reason            : %s\n', char(prediction.Reason));
fprintf('Model source      : %s\n', char(prediction.ModelSource));
fprintf('Verify in Simulink: 1\n');
fprintf('Online update     : %d\n', inputSpec.UpdateModel);
fprintf('Synthetic outputs : NO\n');
fprintf('====================================================\n');

if prediction.Decision == "RECOMMEND"
    [summary, wasSimulated, usedCache, rowAdded, onlineDataset] = ...
        evaluateRealCandidate( ...
            inputSpec, prediction.KP, prediction.KI, ...
            "ML_RECOMMENDATION", cfg, stage11Output.RealRows, ...
            legacyDataset, targetedDataset, onlineDataset, ...
            onlineMATFile, onlineCSVFile);
    newRealSimulations = ...
        newRealSimulations + double(wasSimulated);
    measuredCacheUses = measuredCacheUses + double(usedCache);
    newOnlineRows = newOnlineRows + double(rowAdded);
    trace = appendTrace( ...
        trace, "ML_RECOMMENDATION", summary, ...
        wasSimulated, usedCache);
    candidateSummaries = appendUniqueSummary( ...
        candidateSummaries, summary);

    if summary.SimulationSucceeded && summary.SafetyPassed
        selectedSummary = summary;
        selectedSource = "ML_RECOMMENDATION_VALIDATED";
    else
        fprintf(['ML recommendation failed at least one real gate; ' ...
            'measured fallback starts.\n']);
    end
end


%% ============================================================
% FIXED REAL FALLBACK
%% ============================================================

if isempty(selectedSummary)
    fallbackPoints = [ ...
        cfg.Controller.BaselineKP, cfg.Controller.BaselineKI; ...
        cfg.Controller.BenchmarkKP, cfg.Controller.BenchmarkKI; ...
        0.100, 9.00; ...
        cfg.Controller.StrongFixedKP, cfg.Controller.StrongFixedKI];
    fallbackNames = string({ ...
        'FALLBACK_BASELINE'; ...
        'FALLBACK_BENCHMARK'; ...
        'FALLBACK_TARGETED_MID'; ...
        'FALLBACK_STRONG'});

    fprintf('----------------------------------------------------\n');
    fprintf('REAL FALLBACK: 4 fixed protected candidates\n');

    for pointIndex = 1:size(fallbackPoints, 1)
        KP = fallbackPoints(pointIndex, 1);
        KI = fallbackPoints(pointIndex, 2);

        if ~isempty(candidateSummaries) && ...
                any(abs(candidateSummaries.KP - KP) < 1e-12 & ...
                abs(candidateSummaries.KI - KI) < 1e-12)
            continue;
        end

        [summary, wasSimulated, usedCache, rowAdded, onlineDataset] = ...
            evaluateRealCandidate( ...
                inputSpec, KP, KI, fallbackNames(pointIndex), cfg, ...
                stage11Output.RealRows, legacyDataset, ...
                targetedDataset, onlineDataset, ...
                onlineMATFile, onlineCSVFile);
        newRealSimulations = ...
            newRealSimulations + double(wasSimulated);
        measuredCacheUses = measuredCacheUses + double(usedCache);
        newOnlineRows = newOnlineRows + double(rowAdded);
        trace = appendTrace( ...
            trace, fallbackNames(pointIndex), summary, ...
            wasSimulated, usedCache);
        candidateSummaries = appendUniqueSummary( ...
            candidateSummaries, summary);
    end

    feasible = candidateSummaries( ...
        candidateSummaries.SimulationSucceeded & ...
        candidateSummaries.SafetyPassed & ...
        isfinite(candidateSummaries.PerformanceObjective), :);

    if ~isempty(feasible)
        [~, bestIndex] = min(feasible.PerformanceObjective);
        selectedSummary = feasible(bestIndex, :);
        selectedSource = "REAL_FALLBACK_BEST";
    else
        selectedSource = "NO_FEASIBLE_GAIN_IN_FALLBACK_LIBRARY";
    end
end


%% ============================================================
% REAL-DATA-ONLY MODEL UPDATE
%% ============================================================

modelUpdated = false;

if inputSpec.UpdateModel && ...
        (newOnlineRows > 0 || ~isfile(onlineModelFile))
    stage11PolicyRows = stage11Output.RealRows( ...
        stage11Output.RealRows.Role == "POLICY", :);
    deploymentArtifact = retrainFinalArtifact( ...
        stage11Output.FinalArtifact, legacyDataset, ...
        targetedDataset, stage11PolicyRows, onlineDataset, cfg);
    save(onlineModelFile, 'deploymentArtifact', '-v7.3');
    modelUpdated = true;
end


%% ============================================================
% FINAL RESULT
%% ============================================================

result = struct();
result.Stage12Revision = "2.1.0";
result.Mode = "SELECTIVE_ML_REAL_VALIDATION_AND_ONLINE_UPDATE";
result.InputSpec = inputSpec;
result.InitialPrediction = prediction;
result.Trace = trace;
result.SelectedSource = selectedSource;
result.SelectedResult = selectedSummary;
result.NewRealSimulationsThisCall = newRealSimulations;
result.MeasuredCacheUsesThisCall = measuredCacheUses;
result.NewOnlineRealRowsThisCall = newOnlineRows;
result.TotalOnlineRealRows = height(onlineDataset);
result.ModelUpdated = modelUpdated;
result.ResultVerified = ...
    ~isempty(selectedSummary) && ...
    logical(selectedSummary.SimulationSucceeded) && ...
    logical(selectedSummary.SafetyPassed);
result.SyntheticOutputsUsed = false;

save(decisionMATFile, 'result', '-v7.3');
writetable(trace, traceCSVFile);

fprintf('\n');
fprintf('====================================================\n');
fprintf('PFC ML STAGE 12 - FINAL DECISION COMPLETED\n');
fprintf('====================================================\n');
fprintf('Initial ML decision : %s\n', char(prediction.Decision));
fprintf('Final source        : %s\n', char(selectedSource));
fprintf('New real simulations: %d\n', newRealSimulations);
fprintf('Measured cache uses : %d\n', measuredCacheUses);
fprintf('New online real rows: %d\n', newOnlineRows);
fprintf('Total online rows   : %d\n', height(onlineDataset));
fprintf('Model updated       : %d\n', modelUpdated);
fprintf('Synthetic outputs   : 0\n');

if ~isempty(selectedSummary)
    fprintf('Selected KP / KI    : %.10f / %.10f\n', ...
        selectedSummary.KP, selectedSummary.KI);
    fprintf('Measured J          : %.6g\n', ...
        selectedSummary.PerformanceObjective);
    fprintf('Every real gate pass: %d\n', result.ResultVerified);
else
    fprintf('Selected KP / KI    : NONE\n');
    fprintf('Every real gate pass: 0\n');
end

fprintf('Trace CSV           : %s\n', traceCSVFile);
fprintf('Online data MAT     : %s\n', onlineMATFile);

if isfile(onlineModelFile)
    fprintf('Online model MAT    : %s\n', onlineModelFile);
else
    fprintf('Online model MAT    : NOT CREATED\n');
end

fprintf('====================================================\n');
disp(trace);

end


%% ============================================================
% OPTIONS AND ARTIFACT LOADING
%% ============================================================

function inputSpec = completeDeploymentOptions(inputSpec)

if ~isstruct(inputSpec) || ~isscalar(inputSpec)
    error( ...
        'PFCMLStage12:InputMustBeScalarStruct', ...
        'inputSpec must be one scalar structure.');
end

if ~isfield(inputSpec, 'VerifyInSimulink') || ...
        isempty(inputSpec.VerifyInSimulink)
    inputSpec.VerifyInSimulink = true;
end

if ~isfield(inputSpec, 'UpdateModel') || isempty(inputSpec.UpdateModel)
    inputSpec.UpdateModel = logical(inputSpec.VerifyInSimulink);
end

if ~isfield(inputSpec, 'SaveArtifacts') || ...
        isempty(inputSpec.SaveArtifacts)
    inputSpec.SaveArtifacts = false;
end

booleanNames = {'VerifyInSimulink', 'UpdateModel', 'SaveArtifacts'};

for index = 1:numel(booleanNames)
    name = booleanNames{index};
    value = inputSpec.(name);

    if ~(islogical(value) || isnumeric(value)) || ...
            ~isscalar(value) || ~isfinite(double(value)) || ...
            ~ismember(double(value), [0, 1])
        error( ...
            'PFCMLStage12:InvalidBooleanOption', ...
            '%s must be one logical true/false value.', name);
    end

    inputSpec.(name) = logical(value);
end

end


function output = loadStage11Output(scriptFolder)

candidates = string({ ...
    fullfile(scriptFolder, ...
        'pfc_ml_outputs_stage11_prequential_v200', ...
        'pfc_ml_stage11_final_summary.mat'); ...
    fullfile(scriptFolder, 'pfc_ml_stage11_final_summary.mat')});
summaryFile = "";

for index = 1:numel(candidates)
    if isfile(candidates(index))
        summaryFile = candidates(index);
        break;
    end
end

if strlength(summaryFile) == 0
    error( ...
        'PFCMLStage12:Stage11SummaryMissing', ...
        'The passed Stage 11 final summary MAT file was not found.');
end

loaded = load(char(summaryFile), 'output');

if ~isfield(loaded, 'output')
    error( ...
        'PFCMLStage12:MissingStage11Output', ...
        'Stage 11 summary has no output variable.');
end

output = loaded.output;
required = { ...
    'Stage11Revision', 'Summary', 'RealRows', ...
    'FinalArtifact', 'SyntheticOutputsUsed'};

if ~isstruct(output) || ~all(isfield(output, required)) || ...
        string(output.Stage11Revision) ~= "2.0.0" || ...
        logical(output.SyntheticOutputsUsed) || ...
        ~istable(output.Summary) || height(output.Summary) ~= 1 || ...
        ~logical(output.Summary.OverallPass) || ...
        logical(output.Summary.SyntheticOutputsUsed)
    error( ...
        'PFCMLStage12:InvalidStage11Output', ...
        'Stage 12 requires the clean overall-PASS Stage 11 output.');
end

if ~istable(output.RealRows) || ...
        ~ismember('Role', output.RealRows.Properties.VariableNames) || ...
        any(~output.RealRows.SimulationSucceeded) || ...
        any(~output.RealRows.BaselineFileUnchanged)
    error( ...
        'PFCMLStage12:InvalidStage11RealRows', ...
        'Stage 11 real-row integrity verification failed.');
end

end


function [legacyDataset, targetedDataset] = loadDevelopmentData( ...
    scriptFolder, cfg, required)

legacyFile = fullfile( ...
    scriptFolder, cfg.Files.RootOutputFolder, ...
    cfg.Files.Stage7DatasetMAT);
targetedFile = fullfile( ...
    scriptFolder, 'pfc_ml_outputs_stage9_v180', ...
    'pfc_ml_stage9_targeted_real_dataset.mat');
legacyDataset = table();
targetedDataset = table();

if ~isfile(legacyFile) || ~isfile(targetedFile)
    if required
        error( ...
            'PFCMLStage12:DevelopmentDataMissing', ...
            ['Online learning requires the existing folders ' ...
             'pfc_ml_outputs_stage7_v160 and ' ...
             'pfc_ml_outputs_stage9_v180. Restore them or call with ' ...
             'UpdateModel=false.']);
    end

    return;
end


legacyLoaded = load(legacyFile, 'dataset');
targetedLoaded = load(targetedFile, 'newDataset');

if ~isfield(legacyLoaded, 'dataset') || ...
        ~isfield(targetedLoaded, 'newDataset')
    error( ...
        'PFCMLStage12:DevelopmentVariableMissing', ...
        'Stage 7 or Stage 9 dataset variable is missing.');
end

legacyDataset = legacyLoaded.dataset;
targetedDataset = targetedLoaded.newDataset;
validateBaseDataset(legacyDataset, "Stage 7 dataset");
validateBaseDataset(targetedDataset, "Stage 9 dataset");

if ~ismember('Split', targetedDataset.Properties.VariableNames)
    error( ...
        'PFCMLStage12:Stage9SplitMissing', ...
        'Stage 9 dataset must contain the predeclared Split variable.');
end

end


%% ============================================================
% REAL CANDIDATE ACQUISITION
%% ============================================================

function [summary, wasSimulated, usedCache, rowAdded, onlineDataset] = ...
    evaluateRealCandidate( ...
        inputSpec, KP, KI, source, cfg, stage11Rows, ...
        legacyDataset, targetedDataset, onlineDataset, ...
        onlineMATFile, onlineCSVFile)

summary = lookupMeasuredSummary( ...
    inputSpec, KP, KI, onlineDataset, stage11Rows, ...
    targetedDataset, legacyDataset);
wasSimulated = false;
usedCache = ~isempty(summary);

if isempty(summary)
    caseSpec = struct();
    caseSpec.ScenarioID = ...
        string(inputSpec.ScenarioID) + "_" + string(source);
    caseSpec.RandomSeed = cfg.Project.RandomSeed + ...
        12000 + height(onlineDataset);
    caseSpec.Vin_RMS = inputSpec.Vin_RMS;
    caseSpec.Pload_Pre_W = inputSpec.Pload_Pre_W;
    caseSpec.Pload_High_W = inputSpec.Pload_High_W;
    caseSpec.BoostInductance_H = ...
        1e-6 .* inputSpec.BoostInductance_uH;
    caseSpec.DCBusCapacitance_F = ...
        1e-6 .* inputSpec.DCBusCapacitance_uF;
    caseSpec.LineFrequency_Hz = inputSpec.LineFrequency_Hz;
    caseSpec.KP = KP;
    caseSpec.KI = KI;
    caseSpec.Profile = "Diagnostic";
    caseSpec.SaveArtifacts = inputSpec.SaveArtifacts;
    caseSpec.GainDomain = "BoundaryProbe";

    caseResult = run_single_pfc_case(caseSpec);
    summary = caseResult.SummaryTable;
    wasSimulated = true;
end

summary.ScenarioID = string(inputSpec.ScenarioID);
[~, ~, ~, feasible] = deriveSafetyLabels(summary, cfg);

if logical(feasible) ~= logical(summary.SafetyPassed)
    error( ...
        'PFCMLStage12:RunnerLabelAuditFailed', ...
        ['Derived feasibility disagrees with the protected runner ' ...
         'for KP=%.10g, KI=%.10g.'], KP, KI);
end

[onlineDataset, rowAdded] = appendMeasuredOnlineRow( ...
    onlineDataset, summary, source, logical(feasible));

if rowAdded
    save(onlineMATFile, 'onlineDataset', '-v7.3');
    writetable(onlineDataset, onlineCSVFile);
end

if wasSimulated
    fprintf('SIM   | %-23s | KP=%.6g KI=%.6g | Safe=%d | J=%.6g\n', ...
        char(source), KP, KI, summary.SafetyPassed, ...
        summary.PerformanceObjective);
else
    fprintf('CACHE | %-23s | KP=%.6g KI=%.6g | Safe=%d | J=%.6g\n', ...
        char(source), KP, KI, summary.SafetyPassed, ...
        summary.PerformanceObjective);
end

end


function summary = lookupMeasuredSummary( ...
    inputSpec, KP, KI, onlineDataset, stage11Rows, ...
    targetedDataset, legacyDataset)

summary = table();
sources = {onlineDataset, stage11Rows, targetedDataset, legacyDataset};
summaryNames = baseSummaryVariableNames();

for sourceIndex = 1:numel(sources)
    data = sources{sourceIndex};

    if isempty(data) || ...
            ~all(ismember(summaryNames, data.Properties.VariableNames))
        continue;
    end

    mask = ...
        abs(data.Vin_RMS - inputSpec.Vin_RMS) < 1e-9 & ...
        abs(data.Pload_Pre_W - inputSpec.Pload_Pre_W) < 1e-9 & ...
        abs(data.Pload_High_W - inputSpec.Pload_High_W) < 1e-9 & ...
        abs(data.BoostInductance_uH - ...
            inputSpec.BoostInductance_uH) < 1e-9 & ...
        abs(data.DCBusCapacitance_uF - ...
            inputSpec.DCBusCapacitance_uF) < 1e-9 & ...
        abs(data.LineFrequency_Hz - ...
            inputSpec.LineFrequency_Hz) < 1e-9 & ...
        abs(data.KP - KP) < 1e-12 & ...
        abs(data.KI - KI) < 1e-12 & ...
        data.SimulationSucceeded & data.BaselineFileUnchanged;

    if any(mask)
        summary = data(find(mask, 1, 'last'), summaryNames);
        return;
    end
end

end


function [onlineDataset, rowAdded] = appendMeasuredOnlineRow( ...
    onlineDataset, summary, source, feasible)

row = addvars( ...
    summary, log(summary.KP), log(summary.KI), ...
    string(source), datetime('now'), logical(feasible), ...
    'After', 'KI', ...
    'NewVariableNames', { ...
        'LogKP', 'LogKI', 'AcquisitionSource', ...
        'AcquiredAt', 'Feasible'});
rowAdded = false;

if isempty(onlineDataset)
    onlineDataset = row;
    rowAdded = true;
    return;
end

duplicate = ...
    abs(onlineDataset.Vin_RMS - row.Vin_RMS) < 1e-9 & ...
    abs(onlineDataset.Pload_Pre_W - row.Pload_Pre_W) < 1e-9 & ...
    abs(onlineDataset.Pload_High_W - row.Pload_High_W) < 1e-9 & ...
    abs(onlineDataset.BoostInductance_uH - ...
        row.BoostInductance_uH) < 1e-9 & ...
    abs(onlineDataset.DCBusCapacitance_uF - ...
        row.DCBusCapacitance_uF) < 1e-9 & ...
    abs(onlineDataset.LineFrequency_Hz - ...
        row.LineFrequency_Hz) < 1e-9 & ...
    abs(onlineDataset.KP - row.KP) < 1e-12 & ...
    abs(onlineDataset.KI - row.KI) < 1e-12;

if ~any(duplicate)
    onlineDataset = [onlineDataset; row]; %#ok<AGROW>
    rowAdded = true;
end

end


function summaries = appendUniqueSummary(summaries, summary)

if isempty(summaries)
    summaries = summary;
    return;
end

duplicate = ...
    abs(summaries.KP - summary.KP) < 1e-12 & ...
    abs(summaries.KI - summary.KI) < 1e-12;

if ~any(duplicate)
    summaries = [summaries; summary]; %#ok<AGROW>
end

end


function trace = appendTrace( ...
    trace, source, summary, wasSimulated, usedCache)

row = table( ...
    string(source), summary.KP, summary.KI, ...
    logical(wasSimulated), logical(usedCache), ...
    summary.SimulationSucceeded, summary.SafetyPassed, ...
    summary.PerformanceObjective, summary.HighLoadMean_V, ...
    summary.GlobalVoutMinimum_V, summary.GlobalVoutMaximum_V, ...
    summary.ILPeak_A, summary.PowerFactor, summary.THD_Percent, ...
    'VariableNames', { ...
        'Source', 'KP', 'KI', 'WasSimulated', 'UsedMeasuredCache', ...
        'SimulationSucceeded', 'Feasible', 'PerformanceObjective', ...
        'HighLoadMean_V', 'GlobalVoutMinimum_V', ...
        'GlobalVoutMaximum_V', 'ILPeak_A', ...
        'PowerFactor', 'THD_Percent'});

if isempty(trace)
    trace = row;
else
    trace = [trace; row]; %#ok<AGROW>
end

end


%% ============================================================
% REAL-DATA-ONLY RETRAINING
%% ============================================================

function artifact = retrainFinalArtifact( ...
    frozenArtifact, legacyDataset, targetedDataset, ...
    stage11PolicyRows, stage12Rows, cfg)

targetedTrain = targetedDataset(targetedDataset.Split == "train", :);
legacy = canonicalTrainingRows(legacyDataset, cfg);
targeted = canonicalTrainingRows(targetedTrain, cfg);
stage11 = canonicalTrainingRows(stage11PolicyRows, cfg);
stage12 = canonicalTrainingRows(stage12Rows, cfg);
combined = [legacy; targeted; stage11; stage12];
predictorNames = cellstr(cfg.Stage7.PredictorNames);

% Do not overweight a deterministic cached measurement.
[~, uniqueIndices] = unique( ...
    combined{:, predictorNames}, 'rows', 'stable');
combined = combined(uniqueIndices, :);
X = combined{:, predictorNames};
performanceMask = ...
    combined.Feasible & ...
    isfinite(combined.PerformanceObjective) & ...
    combined.PerformanceObjective > 0.0;

if sum(performanceMask) < cfg.Stage7.MinimumSafeTrainingRows
    error( ...
        'PFCMLStage12:TooFewSafeTrainingRows', ...
        'Too few real safe rows remain for GPR retraining.');
end

rng(cfg.Project.RandomSeed + 1200 + height(stage12Rows), 'twister');
performanceGPR = fitrgp( ...
    X(performanceMask, :), ...
    log(combined.PerformanceObjective(performanceMask)), ...
    'KernelFunction', 'ardsquaredexponential', ...
    'BasisFunction', 'constant', ...
    'Standardize', true);
tree = templateTree('MaxNumSplits', 20, 'MinLeafSize', 1);
classifier = fitcensemble( ...
    X, double(combined.Feasible), ...
    'Method', 'Bag', 'NumLearningCycles', 400, ...
    'Learners', tree, 'ClassNames', [0; 1], 'Prior', 'uniform');
lowVout = cfg.Safety.LateHighLoadVoutRange_V(1);
highVout = cfg.Safety.LateHighLoadVoutRange_V(2);
margin = min( ...
    combined.HighLoadMean_V - lowVout, ...
    highVout - combined.HighLoadMean_V);
regulationMask = isfinite(margin) & all(isfinite(X), 2);
regulationGPR = fitrgp( ...
    X(regulationMask, :), margin(regulationMask), ...
    'KernelFunction', 'ardsquaredexponential', ...
    'BasisFunction', 'constant', ...
    'Standardize', true);

artifact = frozenArtifact;
artifact.Stage12Revision = "2.1.0";
artifact.PerformanceGPR = performanceGPR;
artifact.FeasibilityClassifier = classifier;
artifact.RegulationMarginGPR = regulationGPR;
artifact.DevelopmentPhysical = unique(X(:, 1:6), 'rows');
artifact.DeploymentTrainingRows = height(combined);
artifact.Stage11PolicyRows = height(stage11PolicyRows);
artifact.Stage12OnlineRealRows = height(stage12Rows);
artifact.ReferenceRowsUsedForTraining = false;
artifact.PredictedRowsUsedForTraining = false;
artifact.SyntheticOutputsUsed = false;
artifact.DeploymentMode = ...
    "FINAL_SELECTIVE_ML_REAL_VALIDATION_REAL_DATA_ONLINE_UPDATE";
artifact.UpdatedAt = datetime('now');

end


function rows = canonicalTrainingRows(data, cfg)

if isempty(data)
    names = [cellstr(cfg.Stage7.PredictorNames); ...
        {'PerformanceObjective'; 'HighLoadMean_V'; 'Feasible'}];
    rows = table('Size', [0, numel(names)], ...
        'VariableTypes', repmat({'double'}, 1, numel(names)), ...
        'VariableNames', names);
    return;
end

if ~ismember('LogKP', data.Properties.VariableNames)
    data.LogKP = log(data.KP);
end

if ~ismember('LogKI', data.Properties.VariableNames)
    data.LogKI = log(data.KI);
end

[~, ~, ~, feasible] = deriveSafetyLabels(data, cfg);
data.Feasible = feasible;
names = [cellstr(cfg.Stage7.PredictorNames); ...
    {'PerformanceObjective'; 'HighLoadMean_V'; 'Feasible'}];
rows = data(:, names);

end


%% ============================================================
% SAFETY LABELS AND SCHEMA
%% ============================================================

function [hardPassed, regulationPassed, qualityPassed, feasible] = ...
    deriveSafetyLabels(data, cfg)

metricNames = { ...
    'PreLoadMean_V', 'HighLoadMean_V', 'PostLoadMean_V', ...
    'SteadyStateError_V', 'LoadOnUndershoot_V', ...
    'LoadOffOvershoot_V', 'LoadOnSettling_s', ...
    'LoadOffSettling_s', 'HighLoadRipple_Vpp', ...
    'GlobalVoutMinimum_V', 'GlobalVoutMaximum_V', 'ILPeak_A', ...
    'PowerFactor', 'THD_Percent', 'InputPower_W', ...
    'DutyMinimum', 'DutyMaximum', 'DutyMeanHigh', ...
    'DutySaturationFraction', 'DutyStepRMS', 'IrefPeak_A', ...
    'IrefMeanAbsHigh_A', 'IrefSaturationFraction', ...
    'IrefStepRMS_A'};

if ~all(ismember(metricNames, data.Properties.VariableNames))
    error( ...
        'PFCMLStage12:MetricSchemaMismatch', ...
        'A real dataset is missing required measured metrics.');
end

finiteMetrics = all(isfinite(data{:, metricNames}), 2);
hardPassed = ...
    logical(data.SimulationSucceeded) & finiteMetrics & ...
    data.GlobalVoutMinimum_V >= cfg.Safety.GlobalVoutMinimum_V & ...
    data.GlobalVoutMaximum_V <= cfg.Safety.GlobalVoutMaximum_V & ...
    data.ILPeak_A <= cfg.Safety.InductorPeakMaximum_A & ...
    data.DutyMinimum >= -cfg.Safety.DutyCommandTolerance & ...
    data.DutyMaximum <= ...
        cfg.Controller.DutyMaximum + cfg.Safety.DutyCommandTolerance & ...
    data.IrefPeak_A <= ...
        cfg.Controller.FixedIampMax_A + ...
        cfg.Safety.IrefCommandTolerance_A;
regulationPassed = ...
    logical(data.SimulationSucceeded) & finiteMetrics & ...
    data.HighLoadMean_V >= cfg.Safety.LateHighLoadVoutRange_V(1) & ...
    data.HighLoadMean_V <= cfg.Safety.LateHighLoadVoutRange_V(2);
qualityPassed = ...
    logical(data.SimulationSucceeded) & finiteMetrics & ...
    data.PowerFactor >= cfg.Safety.PowerFactorMinimum & ...
    data.THD_Percent <= cfg.Safety.THDMaximum_Percent;
feasible = hardPassed & regulationPassed & qualityPassed;

end


function validateBaseDataset(data, label)

if ~istable(data)
    error( ...
        'PFCMLStage12:DatasetTypeMismatch', ...
        '%s must be a MATLAB table.', char(label));
end

required = baseSummaryVariableNames();
missing = setdiff(required, data.Properties.VariableNames, 'stable');

if ~isempty(missing)
    error( ...
        'PFCMLStage12:DatasetSchemaMismatch', ...
        '%s is missing variables: %s', ...
        char(label), strjoin(missing, ', '));
end

end


function validateOnlineDataset(data)

validateBaseDataset(data, "Stage 12 online dataset");
required = {'LogKP', 'LogKI', 'AcquisitionSource', ...
    'AcquiredAt', 'Feasible'};

if ~all(ismember(required, data.Properties.VariableNames))
    error( ...
        'PFCMLStage12:OnlineDatasetSchemaMismatch', ...
        'Stage 12 online dataset has an incompatible schema.');
end

end


function names = baseSummaryVariableNames()

names = { ...
    'ScenarioID', 'Vin_RMS', 'Pload_Pre_W', 'Pload_High_W', ...
    'BoostInductance_uH', 'DCBusCapacitance_uF', ...
    'LineFrequency_Hz', 'KP', 'KI', 'IAMP_MAX_A', ...
    'SimulationSucceeded', 'SafetyPassed', 'Objective', ...
    'PerformanceObjective', 'PreLoadMean_V', 'HighLoadMean_V', ...
    'PostLoadMean_V', 'SteadyStateError_V', ...
    'LoadOnUndershoot_V', 'LoadOffOvershoot_V', ...
    'LoadOnSettling_s', 'LoadOffSettling_s', ...
    'HighLoadRipple_Vpp', 'GlobalVoutMinimum_V', ...
    'GlobalVoutMaximum_V', 'ILPeak_A', 'PowerFactor', ...
    'THD_Percent', 'InputPower_W', 'DutyMinimum', ...
    'DutyMaximum', 'DutyMeanHigh', 'DutySaturationFraction', ...
    'DutyStepRMS', 'IrefPeak_A', 'IrefMeanAbsHigh_A', ...
    'IrefSaturationFraction', 'IrefStepRMS_A', ...
    'ElapsedTime_s', 'BaselineFileUnchanged', ...
    'ErrorIdentifier', 'ErrorMessage'};

end


function result = createPredictionOnlyResult(prediction, onlineDataset)

result = struct();
result.Stage12Revision = "2.1.0";
result.Mode = "ML_INFERENCE_ONLY_UNVERIFIED";
result.InputSpec = prediction.InputSpec;
result.InitialPrediction = prediction;
result.Trace = table();
result.SelectedSource = "UNVERIFIED_ML_PREDICTION";
result.SelectedResult = table();
result.NewRealSimulationsThisCall = 0;
result.MeasuredCacheUsesThisCall = 0;
result.NewOnlineRealRowsThisCall = 0;
result.TotalOnlineRealRows = height(onlineDataset);
result.ModelUpdated = false;
result.ResultVerified = false;
result.SyntheticOutputsUsed = false;

end
