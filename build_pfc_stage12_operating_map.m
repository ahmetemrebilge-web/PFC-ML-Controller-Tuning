function map = build_pfc_stage12_operating_map(inputSpec)
%BUILD_PFC_STAGE12_OPERATING_MAP Prediction-only Vin/load gain map.
%
% The map visualizes the deployed Stage 12 ML policy across input voltage
% and high-load operating points while keeping pre-load, L, C, and line
% frequency fixed. Values are model predictions, not measured Simulink
% labels. No model update or synthetic output label is produced.
%
% Revision: 2.2.0
% MATLAB release: R2025a

cfg = pfc_ml_config();

if nargin < 1 || isempty(inputSpec)
    inputSpec = struct();
end

inputSpec = completeInput(inputSpec);
validateInput(inputSpec, cfg);
[artifact, modelSource] = loadActiveArtifact( ...
    fileparts(mfilename('fullpath')));
vinValues = linspace( ...
    cfg.Physical.InputVoltageRange_Vrms(1), ...
    cfg.Physical.InputVoltageRange_Vrms(2), 11);
loadValues = linspace( ...
    cfg.Load.ScenarioHighLoadRange_W(1), ...
    cfg.Load.ScenarioHighLoadRange_W(2), 11);

[loadGrid, vinGrid] = meshgrid(loadValues, vinValues);
pointCount = numel(vinGrid);
physicalGrid = [ ...
    vinGrid(:), repmat(inputSpec.Pload_Pre_W, pointCount, 1), ...
    loadGrid(:), ...
    repmat(inputSpec.BoostInductance_uH, pointCount, 1), ...
    repmat(inputSpec.DCBusCapacitance_uF, pointCount, 1), ...
    repmat(inputSpec.LineFrequency_Hz, pointCount, 1)];

fprintf('\n');
fprintf('====================================================\n');
fprintf('PFC ML STAGE 12 - OPERATING MAP INFERENCE\n');
fprintf('====================================================\n');
fprintf('Grid              : %d Vin x %d high-load points\n', ...
    numel(vinValues), numel(loadValues));
fprintf('Fixed pre-load    : %.1f W\n', inputSpec.Pload_Pre_W);
fprintf('Fixed L / C / f   : %.1f uH / %.1f uF / %.2f Hz\n', ...
    inputSpec.BoostInductance_uH, ...
    inputSpec.DCBusCapacitance_uF, inputSpec.LineFrequency_Hz);
fprintf('Model source      : %s\n', char(modelSource));
fprintf('Simulink executed : NO\n');
fprintf('Synthetic outputs : NO\n');
fprintf('====================================================\n');

batch = searchPolicyBatch(artifact, physicalGrid);
KP = reshape(batch.KP, size(vinGrid));
KI = reshape(batch.KI, size(vinGrid));
predictedJ = reshape(batch.PredictedObjective, size(vinGrid));
pFeasible = reshape(batch.FeasibilityProbability, size(vinGrid));
regulationLCB = reshape(batch.RegulationMarginLCB_V, size(vinGrid));
domainDistance = reshape(batch.DomainDistance, size(vinGrid));
decision = reshape(batch.Decision, size(vinGrid));
reason = reshape(batch.Reason, size(vinGrid));

map = struct();
map.Revision = "2.2.0";
map.ModelSource = modelSource;
map.InputSpec = inputSpec;
map.VinValues = vinValues;
map.HighLoadValues = loadValues;
map.KP = KP;
map.KI = KI;
map.PredictedObjective = predictedJ;
map.FeasibilityProbability = pFeasible;
map.RegulationMarginLCB_V = regulationLCB;
map.DomainDistance = domainDistance;
map.Decision = decision;
map.Reason = reason;
map.RecommendationFraction = mean(decision(:) == "RECOMMEND");
map.SimulationExecuted = false;
map.ModelUpdated = false;
map.SyntheticOutputsUsed = false;
map.PointTable = createPointTable(map);

fprintf('Recommended cells : %d/%d (%.1f %%)\n', ...
    nnz(decision == "RECOMMEND"), numel(decision), ...
    100 .* map.RecommendationFraction);
fprintf('Map status        : PREDICTION ONLY - NOT MEASURED\n');
fprintf('====================================================\n');

end


function inputSpec = completeInput(inputSpec)

defaults = struct();
defaults.ScenarioID = "STAGE12_OPERATING_MAP";
defaults.Pload_Pre_W = 350;
defaults.BoostInductance_uH = 311;
defaults.DCBusCapacitance_uF = 1360;
defaults.LineFrequency_Hz = 50;
names = fieldnames(defaults);

for index = 1:numel(names)
    name = names{index};

    if ~isfield(inputSpec, name) || isempty(inputSpec.(name))
        inputSpec.(name) = defaults.(name);
    end
end

end


function validateInput(inputSpec, cfg)

values = [ ...
    inputSpec.Pload_Pre_W, inputSpec.BoostInductance_uH, ...
    inputSpec.DCBusCapacitance_uF, inputSpec.LineFrequency_Hz];

if any(~isfinite(values)) || any(~isreal(values))
    error('PFCMLMap:InvalidInput', ...
        'Map inputs must be finite real numeric scalars.');
end

LBounds = 1e6 .* cfg.Physical.BoostInductanceRange_H;
CBounds = 1e6 .* cfg.Physical.DCBusCapacitanceRange_F;

if inputSpec.Pload_Pre_W < cfg.Load.ScenarioPreLoadRange_W(1) || ...
        inputSpec.Pload_Pre_W > cfg.Load.ScenarioPreLoadRange_W(2) || ...
        inputSpec.BoostInductance_uH < LBounds(1) || ...
        inputSpec.BoostInductance_uH > LBounds(2) || ...
        inputSpec.DCBusCapacitance_uF < CBounds(1) || ...
        inputSpec.DCBusCapacitance_uF > CBounds(2) || ...
        inputSpec.LineFrequency_Hz < ...
            cfg.Physical.LineFrequencyRange_Hz(1) || ...
        inputSpec.LineFrequency_Hz > ...
            cfg.Physical.LineFrequencyRange_Hz(2)
    error('PFCMLMap:OutsideProtectedDomain', ...
        'A fixed operating-map input is outside the protected domain.');
end

end


function [artifact, modelSource] = loadActiveArtifact(scriptFolder)

summaryFile = fullfile(scriptFolder, ...
    'pfc_ml_outputs_stage11_prequential_v200', ...
    'pfc_ml_stage11_final_summary.mat');

if ~isfile(summaryFile)
    summaryFile = fullfile(scriptFolder, ...
        'pfc_ml_stage11_final_summary.mat');
end

if ~isfile(summaryFile)
    error('PFCMLMap:Stage11SummaryMissing', ...
        'The passed Stage 11 summary MAT file was not found.');
end

loaded = load(summaryFile, 'output');

if ~isfield(loaded, 'output') || ...
        ~isfield(loaded.output, 'FinalArtifact') || ...
        ~isfield(loaded.output, 'SyntheticOutputsUsed') || ...
        logical(loaded.output.SyntheticOutputsUsed)
    error('PFCMLMap:InvalidStage11Artifact', ...
        'The Stage 11 artifact is missing or reports synthetic outputs.');
end

artifact = loaded.output.FinalArtifact;
modelSource = "STAGE11_FINAL_ARTIFACT";
onlineFile = fullfile(scriptFolder, ...
    'pfc_ml_outputs_stage12_final_v210', ...
    'pfc_ml_stage12_online_models.mat');

if isfile(onlineFile)
    online = load(onlineFile, 'deploymentArtifact');

    if isfield(online, 'deploymentArtifact') && ...
            isfield(online.deploymentArtifact, 'SyntheticOutputsUsed') && ...
            ~logical(online.deploymentArtifact.SyntheticOutputsUsed)
        artifact = online.deploymentArtifact;
        modelSource = "STAGE12_REAL_DATA_UPDATED_ARTIFACT";
    end
end

required = { ...
    'PerformanceGPR', 'FeasibilityClassifier', ...
    'RegulationMarginGPR', 'FeasibilityProbabilityThreshold', ...
    'RegulationErrorBuffer_V', 'RegulationConfidenceZ', ...
    'ObjectiveStdLimit', 'ObjectiveConfidenceZ', ...
    'DevelopmentPhysical', 'PhysicalScale', ...
    'DomainDistanceLimit', 'GridSize', 'KPBounds', 'KIBounds'};

if ~all(isfield(artifact, required))
    error('PFCMLMap:ArtifactSchemaMismatch', ...
        'The active ML artifact schema is incomplete.');
end

end


function batch = searchPolicyBatch(artifact, physicalGrid)

physicalCount = size(physicalGrid, 1);
domainDistance = NaN(physicalCount, 1);

for index = 1:physicalCount
    domainDistance(index) = nearestDistance( ...
        physicalGrid(index, :), artifact.DevelopmentPhysical, ...
        artifact.PhysicalScale);
end

logKP = linspace(log(artifact.KPBounds(1)), ...
    log(artifact.KPBounds(2)), artifact.GridSize);
logKI = linspace(log(artifact.KIBounds(1)), ...
    log(artifact.KIBounds(2)), artifact.GridSize);
[logKPGrid, logKIGrid] = ndgrid(logKP, logKI);
gainCount = numel(logKPGrid);
X = [ ...
    repelem(physicalGrid, gainCount, 1), ...
    repmat(logKPGrid(:), physicalCount, 1), ...
    repmat(logKIGrid(:), physicalCount, 1)];
probability = safeProbability(artifact.FeasibilityClassifier, X);
[logObjective, logObjectiveSD] = predict(artifact.PerformanceGPR, X);
[margin, marginSD] = predict(artifact.RegulationMarginGPR, X);
marginLCB = margin - artifact.RegulationConfidenceZ .* marginSD - ...
    artifact.RegulationErrorBuffer_V;
riskObjective = logObjective + ...
    artifact.ObjectiveConfidenceZ .* logObjectiveSD;
probability = reshape(probability, gainCount, physicalCount);
logObjective = reshape(logObjective, gainCount, physicalCount);
logObjectiveSD = reshape(logObjectiveSD, gainCount, physicalCount);
marginLCB = reshape(marginLCB, gainCount, physicalCount);
riskObjective = reshape(riskObjective, gainCount, physicalCount);
eligible = ...
    probability >= artifact.FeasibilityProbabilityThreshold & ...
    marginLCB >= 0 & ...
    logObjectiveSD <= artifact.ObjectiveStdLimit;

batch = struct();
batch.KP = NaN(physicalCount, 1);
batch.KI = NaN(physicalCount, 1);
batch.PredictedObjective = NaN(physicalCount, 1);
batch.FeasibilityProbability = NaN(physicalCount, 1);
batch.RegulationMarginLCB_V = NaN(physicalCount, 1);
batch.DomainDistance = domainDistance;
batch.Decision = repmat("ABSTAIN", physicalCount, 1);
batch.Reason = strings(physicalCount, 1);

for index = 1:physicalCount
    pointEligible = eligible(:, index);

    if domainDistance(index) > artifact.DomainDistanceLimit
        pointEligible(:) = false;
    end

    if any(pointEligible)
        candidates = find(pointEligible);
        [~, localBest] = min(riskObjective(pointEligible, index));
        best = candidates(localBest);
        batch.Decision(index) = "RECOMMEND";
        batch.Reason(index) = "ALL_GATES_PASSED";
        batch.KP(index) = exp(logKPGrid(best));
        batch.KI(index) = exp(logKIGrid(best));
        batch.PredictedObjective(index) = exp(logObjective(best, index));
        batch.FeasibilityProbability(index) = probability(best, index);
        batch.RegulationMarginLCB_V(index) = marginLCB(best, index);
    else
        batch.FeasibilityProbability(index) = max(probability(:, index));
        batch.RegulationMarginLCB_V(index) = max(marginLCB(:, index));

        if domainDistance(index) > artifact.DomainDistanceLimit
            batch.Reason(index) = "OUTSIDE_SUPPORTED_PHYSICAL_DOMAIN";
        elseif batch.FeasibilityProbability(index) < ...
                artifact.FeasibilityProbabilityThreshold
            batch.Reason(index) = "LOW_FEASIBILITY_PROBABILITY";
        elseif batch.RegulationMarginLCB_V(index) < 0
            batch.Reason(index) = "NO_POSITIVE_REGULATION_MARGIN";
        else
            batch.Reason(index) = "OBJECTIVE_UNCERTAINTY_TOO_HIGH";
        end
    end
end

end


function probability = safeProbability(model, X)

[~, score] = predict(model, X);
classes = double(model.ClassNames(:));
safeColumn = find(classes == 1, 1);

if isempty(safeColumn)
    error('PFCMLMap:ClassifierClassMismatch', ...
        'The feasibility classifier has no safe-class score.');
end

probability = min(max(score(:, safeColumn), 0), 1);

end


function distance = nearestDistance(query, references, scale)

difference = (references - query) ./ scale;
distance = min(sqrt(sum(difference .^ 2, 2)));

end


function pointTable = createPointTable(map)

[loadGrid, vinGrid] = meshgrid(map.HighLoadValues, map.VinValues);
pointTable = table( ...
    vinGrid(:), loadGrid(:), ...
    repmat(map.InputSpec.Pload_Pre_W, numel(vinGrid), 1), ...
    repmat(map.InputSpec.BoostInductance_uH, numel(vinGrid), 1), ...
    repmat(map.InputSpec.DCBusCapacitance_uF, numel(vinGrid), 1), ...
    repmat(map.InputSpec.LineFrequency_Hz, numel(vinGrid), 1), ...
    map.Decision(:), map.Reason(:), map.KP(:), map.KI(:), ...
    map.PredictedObjective(:), map.FeasibilityProbability(:), ...
    map.RegulationMarginLCB_V(:), map.DomainDistance(:), ...
    false(numel(vinGrid), 1), false(numel(vinGrid), 1), ...
    'VariableNames', { ...
        'Vin_RMS', 'Pload_High_W', 'Pload_Pre_W', ...
        'BoostInductance_uH', 'DCBusCapacitance_uF', ...
        'LineFrequency_Hz', 'Decision', 'Reason', 'KP', 'KI', ...
        'PredictedObjective', 'FeasibilityProbability', ...
        'RegulationMarginLCB_V', 'DomainDistance', ...
        'SimulationExecuted', 'SyntheticOutputsUsed'});

end
