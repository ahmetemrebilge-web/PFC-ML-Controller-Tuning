function prediction = predict_pfc_stage12_gains(inputSpec)
%PREDICT_PFC_STAGE12_GAINS Fast safety-aware ML gain recommendation.
%
% This function performs ML inference only. It does not run Simulink,
% generate a label, modify the baseline model, or update the ML model.
% The returned KP/KI pair is a recommendation until it is verified with
% run_pfc_stage12_final_hybrid_tuner.
%
% Revision: 2.1.0
% MATLAB release: R2025a


%% ============================================================
% CONFIGURATION AND INPUT
%% ============================================================

cfg = pfc_ml_config();

if string(cfg.Project.ConfigVersion) ~= "1.6.0"
    error( ...
        'PFCMLStage12:WrongConfigRevision', ...
        'Stage 12 requires pfc_ml_config version 1.6.0.');
end

if nargin < 1 || isempty(inputSpec)
    inputSpec = struct();
end

inputSpec = completeInputSpec(inputSpec);
validateInputSpec(inputSpec, cfg);


%% ============================================================
% LOAD THE PASSED STAGE 11 ARTIFACT
%% ============================================================

scriptFolder = fileparts(mfilename('fullpath'));
summaryFile = locateStage11Summary(scriptFolder);
loaded = load(summaryFile, 'output');

if ~isfield(loaded, 'output')
    error( ...
        'PFCMLStage12:MissingStage11Output', ...
        'The Stage 11 summary MAT file has no output variable.');
end

stage11Output = loaded.output;
validateStage11Output(stage11Output);
activeArtifact = stage11Output.FinalArtifact;
modelSource = "STAGE11_FINAL_ARTIFACT";

onlineModelFile = fullfile( ...
    scriptFolder, 'pfc_ml_outputs_stage12_final_v210', ...
    'pfc_ml_stage12_online_models.mat');

if isfile(onlineModelFile)
    onlineLoaded = load(onlineModelFile, 'deploymentArtifact');

    if isfield(onlineLoaded, 'deploymentArtifact') && ...
            isfield(onlineLoaded.deploymentArtifact, ...
                'Stage12Revision') && ...
            string(onlineLoaded.deploymentArtifact.Stage12Revision) == ...
                "2.1.0" && ...
            isfield(onlineLoaded.deploymentArtifact, ...
                'SyntheticOutputsUsed') && ...
            ~logical(onlineLoaded.deploymentArtifact.SyntheticOutputsUsed)
        validateArtifact(onlineLoaded.deploymentArtifact);
        activeArtifact = onlineLoaded.deploymentArtifact;
        modelSource = "STAGE12_REAL_DATA_UPDATED_ARTIFACT";
    end
end


%% ============================================================
% SELECTIVE SAFETY-AWARE SEARCH
%% ============================================================

recommendation = searchSafetyAwareGrid(activeArtifact, inputSpec);

prediction = recommendation;
prediction.Stage12Revision = "2.1.0";
prediction.InputSpec = inputSpec;
prediction.ModelSource = modelSource;
prediction.Stage11SummaryFile = string(summaryFile);
prediction.SimulationExecuted = false;
prediction.ResultVerified = false;
prediction.ModelUpdated = false;
prediction.SyntheticOutputsUsed = false;
prediction.ResultTable = createResultTable(prediction);

fprintf('\n');
fprintf('====================================================\n');
fprintf('PFC ML STAGE 12 - FAST INFERENCE ONLY\n');
fprintf('====================================================\n');
fprintf('Scenario          : %s\n', char(inputSpec.ScenarioID));
fprintf('Model source      : %s\n', char(modelSource));
fprintf('Vin / load        : %.3f VAC | %.1f -> %.1f W\n', ...
    inputSpec.Vin_RMS, inputSpec.Pload_Pre_W, ...
    inputSpec.Pload_High_W);
fprintf('L / C / frequency : %.3f uH / %.3f uF / %.3f Hz\n', ...
    inputSpec.BoostInductance_uH, ...
    inputSpec.DCBusCapacitance_uF, ...
    inputSpec.LineFrequency_Hz);
fprintf('ML decision       : %s\n', char(prediction.Decision));
fprintf('Reason            : %s\n', char(prediction.Reason));
fprintf('P(feasible)       : %.4f\n', ...
    prediction.FeasibilityProbability);
fprintf('Regulation LCB    : %.4f V\n', ...
    prediction.RegulationMarginLCB_V);
fprintf('Domain distance   : %.4f\n', ...
    prediction.DomainDistance);

if prediction.Decision == "RECOMMEND"
    fprintf('Recommended KP/KI : %.10f / %.10f\n', ...
        prediction.KP, prediction.KI);
    fprintf('Predicted J       : %.6g\n', ...
        prediction.PredictedObjective);
else
    fprintf('Recommended KP/KI : NONE - REAL FALLBACK REQUIRED\n');
end

fprintf('Simulink executed : NO\n');
fprintf('Result verified   : NO\n');
fprintf('Synthetic outputs : NO\n');
fprintf(['Next safe action  : run_pfc_stage12_final_hybrid_tuner ' ...
    'with VerifyInSimulink=true\n']);
fprintf('====================================================\n');

end


%% ============================================================
% INPUT HELPERS
%% ============================================================

function inputSpec = completeInputSpec(inputSpec)

if ~isstruct(inputSpec) || ~isscalar(inputSpec)
    error( ...
        'PFCMLStage12:InputMustBeScalarStruct', ...
        'inputSpec must be one scalar structure.');
end

defaults = struct();
defaults.ScenarioID = "STAGE12_USER_CASE";
defaults.Vin_RMS = 205.0;
defaults.Pload_Pre_W = 350.0;
defaults.Pload_High_W = 1300.0;
defaults.BoostInductance_uH = 305.0;
defaults.DCBusCapacitance_uF = 1250.0;
defaults.LineFrequency_Hz = 49.5;
names = fieldnames(defaults);

for index = 1:numel(names)
    name = names{index};

    if ~isfield(inputSpec, name) || isempty(inputSpec.(name))
        inputSpec.(name) = defaults.(name);
    end
end

inputSpec.ScenarioID = string(inputSpec.ScenarioID);

if ~isscalar(inputSpec.ScenarioID) || strlength(inputSpec.ScenarioID) == 0
    error( ...
        'PFCMLStage12:InvalidScenarioID', ...
        'ScenarioID must be one nonempty string.');
end

end


function validateInputSpec(inputSpec, cfg)

names = { ...
    'Vin_RMS', 'Pload_Pre_W', 'Pload_High_W', ...
    'BoostInductance_uH', 'DCBusCapacitance_uF', ...
    'LineFrequency_Hz'};

for index = 1:numel(names)
    value = inputSpec.(names{index});

    if ~isnumeric(value) || ~isscalar(value) || ~isfinite(value) || ...
            ~isreal(value)
        error( ...
            'PFCMLStage12:InvalidPhysicalInput', ...
            '%s must be one finite real numeric scalar.', names{index});
    end
end

if inputSpec.Vin_RMS < cfg.Physical.InputVoltageRange_Vrms(1) || ...
        inputSpec.Vin_RMS > cfg.Physical.InputVoltageRange_Vrms(2)
    error( ...
        'PFCMLStage12:VinOutOfRange', ...
        'Vin_RMS is outside the protected %.1f-%.1f VAC domain.', ...
        cfg.Physical.InputVoltageRange_Vrms(1), ...
        cfg.Physical.InputVoltageRange_Vrms(2));
end

if inputSpec.Pload_Pre_W < cfg.Load.ScenarioPreLoadRange_W(1) || ...
        inputSpec.Pload_Pre_W > cfg.Load.ScenarioPreLoadRange_W(2) || ...
        inputSpec.Pload_High_W < ...
            cfg.Load.ScenarioHighLoadRange_W(1) || ...
        inputSpec.Pload_High_W > ...
            cfg.Load.ScenarioHighLoadRange_W(2) || ...
        inputSpec.Pload_High_W - inputSpec.Pload_Pre_W < ...
            cfg.Load.MinimumLoadStep_W
    error( ...
        'PFCMLStage12:LoadOutOfRange', ...
        ['Loads are outside the protected domain or the load step ' ...
         'is smaller than %.1f W.'], cfg.Load.MinimumLoadStep_W);
end

LBounds = 1e6 .* cfg.Physical.BoostInductanceRange_H;
CBounds = 1e6 .* cfg.Physical.DCBusCapacitanceRange_F;

if inputSpec.BoostInductance_uH < LBounds(1) || ...
        inputSpec.BoostInductance_uH > LBounds(2) || ...
        inputSpec.DCBusCapacitance_uF < CBounds(1) || ...
        inputSpec.DCBusCapacitance_uF > CBounds(2) || ...
        inputSpec.LineFrequency_Hz < ...
            cfg.Physical.LineFrequencyRange_Hz(1) || ...
        inputSpec.LineFrequency_Hz > ...
            cfg.Physical.LineFrequencyRange_Hz(2)
    error( ...
        'PFCMLStage12:PlantValueOutOfRange', ...
        'L, C, or line frequency is outside the protected domain.');
end

end


%% ============================================================
% ARTIFACT HELPERS
%% ============================================================

function summaryFile = locateStage11Summary(scriptFolder)

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
        ['pfc_ml_stage11_final_summary.mat was not found. Keep it ' ...
         'inside pfc_ml_outputs_stage11_prequential_v200.']);
end

summaryFile = char(summaryFile);

end


function validateStage11Output(output)

required = { ...
    'Stage11Revision', 'Protocol', 'Summary', 'RealRows', ...
    'FinalArtifact', 'SyntheticOutputsUsed'};

if ~isstruct(output) || ~all(isfield(output, required))
    error( ...
        'PFCMLStage12:InvalidStage11Summary', ...
        'Stage 11 summary structure is incomplete.');
end

if string(output.Stage11Revision) ~= "2.0.0"
    error( ...
        'PFCMLStage12:WrongStage11Revision', ...
        'Stage 12 requires the passed Stage 11 revision 2.0.0 output.');
end

if logical(output.SyntheticOutputsUsed)
    error( ...
        'PFCMLStage12:SyntheticStage11OutputForbidden', ...
        'The Stage 11 artifact reports synthetic outputs.');
end

if ~istable(output.Summary) || height(output.Summary) ~= 1 || ...
        ~ismember('OverallPass', output.Summary.Properties.VariableNames) || ...
        ~logical(output.Summary.OverallPass) || ...
        ~ismember('SyntheticOutputsUsed', ...
            output.Summary.Properties.VariableNames) || ...
        logical(output.Summary.SyntheticOutputsUsed)
    error( ...
        'PFCMLStage12:Stage11DidNotPass', ...
        'The supplied Stage 11 benchmark is not a clean overall PASS.');
end

validateArtifact(output.FinalArtifact);

end


function validateArtifact(artifact)

required = { ...
    'PerformanceGPR', 'FeasibilityClassifier', ...
    'RegulationMarginGPR', 'FeasibilityProbabilityThreshold', ...
    'RegulationErrorBuffer_V', 'RegulationConfidenceZ', ...
    'ObjectiveStdLimit', 'ObjectiveConfidenceZ', ...
    'DevelopmentPhysical', 'PhysicalScale', ...
    'DomainDistanceLimit', 'GridSize', 'KPBounds', 'KIBounds'};

if ~isstruct(artifact) || ~all(isfield(artifact, required))
    missing = required(~isfield(artifact, required));
    error( ...
        'PFCMLStage12:ArtifactSchemaMismatch', ...
        'Final ML artifact is missing fields: %s', strjoin(missing, ', '));
end

if isfield(artifact, 'SyntheticOutputsUsed') && ...
        logical(artifact.SyntheticOutputsUsed)
    error( ...
        'PFCMLStage12:SyntheticArtifactForbidden', ...
        'The active ML artifact reports synthetic outputs.');
end

if any(~isfinite(artifact.KPBounds)) || ...
        any(~isfinite(artifact.KIBounds)) || ...
        any(artifact.KPBounds <= 0) || any(artifact.KIBounds <= 0) || ...
        artifact.KPBounds(1) >= artifact.KPBounds(2) || ...
        artifact.KIBounds(1) >= artifact.KIBounds(2)
    error( ...
        'PFCMLStage12:InvalidArtifactGainBounds', ...
        'The final artifact contains invalid log-domain gain bounds.');
end

end


%% ============================================================
% SAFETY-AWARE ML SEARCH
%% ============================================================

function recommendation = searchSafetyAwareGrid(artifact, inputSpec)

physical = [ ...
    inputSpec.Vin_RMS, inputSpec.Pload_Pre_W, ...
    inputSpec.Pload_High_W, inputSpec.BoostInductance_uH, ...
    inputSpec.DCBusCapacitance_uF, inputSpec.LineFrequency_Hz];
domainDistance = nearestNormalizedDistance( ...
    physical, artifact.DevelopmentPhysical, artifact.PhysicalScale);
logKP = linspace( ...
    log(artifact.KPBounds(1)), log(artifact.KPBounds(2)), ...
    artifact.GridSize);
logKI = linspace( ...
    log(artifact.KIBounds(1)), log(artifact.KIBounds(2)), ...
    artifact.GridSize);
[logKPGrid, logKIGrid] = ndgrid(logKP, logKI);
count = numel(logKPGrid);
X = [repmat(physical, count, 1), logKPGrid(:), logKIGrid(:)];
probability = predictSafeProbability( ...
    artifact.FeasibilityClassifier, X);
[logObjective, logObjectiveSD] = predict(artifact.PerformanceGPR, X);
[margin, marginSD] = predict(artifact.RegulationMarginGPR, X);
marginLCB = ...
    margin - artifact.RegulationConfidenceZ .* marginSD - ...
    artifact.RegulationErrorBuffer_V;
riskLogObjective = ...
    logObjective + artifact.ObjectiveConfidenceZ .* logObjectiveSD;
eligible = ...
    probability >= artifact.FeasibilityProbabilityThreshold & ...
    marginLCB >= 0.0 & ...
    logObjectiveSD <= artifact.ObjectiveStdLimit;

if domainDistance > artifact.DomainDistanceLimit
    eligible(:) = false;
end

recommendation = struct();
recommendation.DomainDistance = domainDistance;

if any(eligible)
    indices = find(eligible);
    [~, localBest] = min(riskLogObjective(eligible));
    index = indices(localBest);
    recommendation.Decision = "RECOMMEND";
    recommendation.Reason = "ALL_GATES_PASSED";
    recommendation.KP = exp(logKPGrid(index));
    recommendation.KI = exp(logKIGrid(index));
    recommendation.PredictedObjective = exp(logObjective(index));
    recommendation.PredictedLogObjectiveSD = logObjectiveSD(index);
    recommendation.FeasibilityProbability = probability(index);
    recommendation.RegulationMarginLCB_V = marginLCB(index);
else
    [maxProbability, probabilityIndex] = max(probability);
    [maxMarginLCB, marginIndex] = max(marginLCB);
    [minObjectiveSD, uncertaintyIndex] = min(logObjectiveSD);

    if domainDistance > artifact.DomainDistanceLimit
        reason = "OUTSIDE_SUPPORTED_PHYSICAL_DOMAIN";
        diagnosticIndex = uncertaintyIndex;
    elseif maxProbability < artifact.FeasibilityProbabilityThreshold
        reason = "LOW_FEASIBILITY_PROBABILITY";
        diagnosticIndex = probabilityIndex;
    elseif maxMarginLCB < 0.0
        reason = "NO_POSITIVE_REGULATION_MARGIN";
        diagnosticIndex = marginIndex;
    else
        reason = "OBJECTIVE_UNCERTAINTY_TOO_HIGH";
        diagnosticIndex = uncertaintyIndex;
    end

    recommendation.Decision = "ABSTAIN";
    recommendation.Reason = reason;
    recommendation.KP = NaN;
    recommendation.KI = NaN;
    recommendation.PredictedObjective = NaN;
    recommendation.PredictedLogObjectiveSD = minObjectiveSD;
    recommendation.FeasibilityProbability = maxProbability;
    recommendation.RegulationMarginLCB_V = maxMarginLCB;
    recommendation.DiagnosticIndex = diagnosticIndex;
end

end


function probability = predictSafeProbability(model, X)

[~, score] = predict(model, X);
classes = double(model.ClassNames(:));
safeColumn = find(classes == 1, 1);

if isempty(safeColumn)
    error( ...
        'PFCMLStage12:ClassifierClassMismatch', ...
        'The classifier has no feasible-class score.');
end

probability = min(max(score(:, safeColumn), 0.0), 1.0);

end


function distance = nearestNormalizedDistance(query, references, scale)

if isempty(references) || any(~isfinite(scale)) || any(scale <= 0)
    error( ...
        'PFCMLStage12:InvalidPhysicalDomainMetadata', ...
        'The artifact physical-domain metadata is invalid.');
end

difference = (references - query) ./ scale;
distance = min(sqrt(sum(difference.^2, 2)));

end


function resultTable = createResultTable(prediction)

s = prediction.InputSpec;
resultTable = table( ...
    s.ScenarioID, s.Vin_RMS, s.Pload_Pre_W, s.Pload_High_W, ...
    s.BoostInductance_uH, s.DCBusCapacitance_uF, ...
    s.LineFrequency_Hz, string(prediction.ModelSource), ...
    string(prediction.Decision), string(prediction.Reason), ...
    prediction.KP, prediction.KI, ...
    prediction.PredictedObjective, ...
    prediction.PredictedLogObjectiveSD, ...
    prediction.FeasibilityProbability, ...
    prediction.RegulationMarginLCB_V, ...
    prediction.DomainDistance, false, false, false, ...
    'VariableNames', { ...
        'ScenarioID', 'Vin_RMS', 'Pload_Pre_W', 'Pload_High_W', ...
        'BoostInductance_uH', 'DCBusCapacitance_uF', ...
        'LineFrequency_Hz', 'ModelSource', 'Decision', 'Reason', ...
        'KP', 'KI', 'PredictedObjective', ...
        'PredictedLogObjectiveSD', 'FeasibilityProbability', ...
        'RegulationMarginLCB_V', 'DomainDistance', ...
        'SimulationExecuted', 'ResultVerified', ...
        'SyntheticOutputsUsed'});

end
