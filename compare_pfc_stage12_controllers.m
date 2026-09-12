function output = compare_pfc_stage12_controllers(inputSpec)
%COMPARE_PFC_STAGE12_CONTROLLERS Real Simulink controller benchmark.
%
% Compares the baseline PI, the strong fixed PI, and the current ML
% recommendation under exactly the same physical scenario. Every reported
% metric comes from run_single_pfc_case. Existing results may be reused only
% from this function's exact measured-result cache.
%
% Revision: 2.2.1
% MATLAB release: R2025a

cfg = pfc_ml_config();

if nargin < 1 || isempty(inputSpec)
    inputSpec = struct();
end

prediction = predict_pfc_stage12_gains(inputSpec);
inputSpec = prediction.InputSpec;
scriptFolder = fileparts(mfilename('fullpath'));
outputFolder = fullfile(scriptFolder, ...
    'pfc_ml_outputs_stage12_comparison_v220');

if ~isfolder(outputFolder)
    mkdir(outputFolder);
end

cacheFile = fullfile(outputFolder, ...
    'pfc_ml_stage12_controller_comparison_real_cache.mat');
latestMAT = fullfile(outputFolder, ...
    'pfc_ml_stage12_latest_controller_comparison.mat');
latestCSV = fullfile(outputFolder, ...
    'pfc_ml_stage12_latest_controller_comparison.csv');
measurementCache = table();

if isfile(cacheFile)
    loaded = load(cacheFile, 'measurementCache');

    if isfield(loaded, 'measurementCache') && ...
            istable(loaded.measurementCache)
        measurementCache = loaded.measurementCache;
    end
end

names = string({'Baseline PI'; 'Strong fixed PI'});
gains = [ ...
    cfg.Controller.BaselineKP, cfg.Controller.BaselineKI; ...
    cfg.Controller.StrongFixedKP, cfg.Controller.StrongFixedKI];

if prediction.Decision == "RECOMMEND"
    names(end + 1, 1) = "ML recommendation";
    gains(end + 1, :) = [prediction.KP, prediction.KI];
else
    names(end + 1, 1) = "ML abstained";
    gains(end + 1, :) = [NaN, NaN];
end

fprintf('\n');
fprintf('====================================================\n');
fprintf('PFC ML STAGE 12 - REAL CONTROLLER COMPARISON\n');
fprintf('====================================================\n');
fprintf('Scenario          : %s\n', char(inputSpec.ScenarioID));
fprintf('Controllers       : baseline / strong fixed / ML\n');
fprintf('Synthetic outputs : NO\n');
fprintf('Measured cache    : exact real Simulink rows only\n');
fprintf('====================================================\n');

rows = table();
newRealSimulations = 0;
measuredCacheUses = 0;

for index = 1:numel(names)
    if ~all(isfinite(gains(index, :)))
        row = createAbstainRow(inputSpec, names(index));
        rows = appendCompatible(rows, row);
        continue;
    end

    [summary, usedCache] = findExactMeasurement( ...
        measurementCache, inputSpec, gains(index, 1), gains(index, 2));

    if usedCache
        measuredCacheUses = measuredCacheUses + 1;
        wasSimulated = false;
        fprintf('CACHE | %-19s | KP=%.7g KI=%.7g | J=%.6g\n', ...
            char(names(index)), gains(index, 1), gains(index, 2), ...
            summary.PerformanceObjective);
    else
        caseSpec = struct();
        caseSpec.ScenarioID = string(sprintf('%s_CMP_%02d', ...
            char(inputSpec.ScenarioID), index));
        caseSpec.RandomSeed = cfg.Project.RandomSeed + 22000 + index;
        caseSpec.Vin_RMS = inputSpec.Vin_RMS;
        caseSpec.Pload_Pre_W = inputSpec.Pload_Pre_W;
        caseSpec.Pload_High_W = inputSpec.Pload_High_W;
        caseSpec.BoostInductance_H = ...
            1e-6 .* inputSpec.BoostInductance_uH;
        caseSpec.DCBusCapacitance_F = ...
            1e-6 .* inputSpec.DCBusCapacitance_uF;
        caseSpec.LineFrequency_Hz = inputSpec.LineFrequency_Hz;
        caseSpec.KP = gains(index, 1);
        caseSpec.KI = gains(index, 2);
        caseSpec.Profile = "Diagnostic";
        caseSpec.SaveArtifacts = false;
        caseSpec.GainDomain = "BoundaryProbe";
        caseResult = run_single_pfc_case(caseSpec);
        summary = caseResult.SummaryTable;
        wasSimulated = true;
        newRealSimulations = newRealSimulations + 1;
        measurementCache = appendCompatible(measurementCache, summary);
        save(cacheFile, 'measurementCache', '-v7.3');
        fprintf('SIM   | %-19s | KP=%.7g KI=%.7g | Safe=%d | J=%.6g\n', ...
            char(names(index)), gains(index, 1), gains(index, 2), ...
            summary.SafetyPassed, summary.PerformanceObjective);
    end

    row = compactComparisonRow( ...
        names(index), summary, wasSimulated, usedCache);
    rows = appendCompatible(rows, row);
end

safeMask = rows.SimulationSucceeded & rows.SafetyPassed & ...
    isfinite(rows.PerformanceObjective);
bestController = "NONE";

if any(safeMask)
    safeRows = rows(safeMask, :);
    [~, bestIndex] = min(safeRows.PerformanceObjective);
    bestController = safeRows.Controller(bestIndex);
end

baselineJ = rows.PerformanceObjective(rows.Controller == "Baseline PI");
bestJ = rows.PerformanceObjective(rows.Controller == bestController);
improvementPercent = NaN;

if ~isempty(baselineJ) && ~isempty(bestJ) && ...
        isfinite(baselineJ(1)) && baselineJ(1) > 0
    improvementPercent = 100 .* (baselineJ(1) - bestJ(1)) ./ baselineJ(1);
end

output = struct();
output.Revision = "2.2.1";
output.InputSpec = inputSpec;
output.Prediction = prediction;
output.ComparisonTable = rows;
output.BestController = bestController;
output.ImprovementVsBaseline_Percent = improvementPercent;
output.NewRealSimulations = newRealSimulations;
output.MeasuredCacheUses = measuredCacheUses;
output.SyntheticOutputsUsed = false;
output.CacheFile = string(cacheFile);
output.LatestMATFile = string(latestMAT);
output.LatestCSVFile = string(latestCSV);

save(latestMAT, 'output', '-v7.3');
writetable(rows, latestCSV);

fprintf('\n');
fprintf('====================================================\n');
fprintf('REAL CONTROLLER COMPARISON COMPLETED\n');
fprintf('====================================================\n');
fprintf('New real simulations : %d\n', newRealSimulations);
fprintf('Measured cache uses  : %d\n', measuredCacheUses);
fprintf('Best controller      : %s\n', char(bestController));
fprintf('Improvement vs base  : %.3f %%\n', improvementPercent);
fprintf('Synthetic outputs    : 0\n');
fprintf('CSV                   : %s\n', latestCSV);
fprintf('====================================================\n');

end


function [summary, found] = findExactMeasurement(cache, inputSpec, KP, KI)

summary = table();
found = false;

if isempty(cache)
    return;
end

required = { ...
    'Vin_RMS', 'Pload_Pre_W', 'Pload_High_W', ...
    'BoostInductance_uH', 'DCBusCapacitance_uF', ...
    'LineFrequency_Hz', 'KP', 'KI', ...
    'SimulationSucceeded', 'SafetyPassed', ...
    'PerformanceObjective'};

if ~all(ismember(required, cache.Properties.VariableNames))
    return;
end

tolerance = 1e-9;
mask = ...
    abs(cache.Vin_RMS - inputSpec.Vin_RMS) <= tolerance & ...
    abs(cache.Pload_Pre_W - inputSpec.Pload_Pre_W) <= tolerance & ...
    abs(cache.Pload_High_W - inputSpec.Pload_High_W) <= tolerance & ...
    abs(cache.BoostInductance_uH - ...
        inputSpec.BoostInductance_uH) <= tolerance & ...
    abs(cache.DCBusCapacitance_uF - ...
        inputSpec.DCBusCapacitance_uF) <= tolerance & ...
    abs(cache.LineFrequency_Hz - ...
        inputSpec.LineFrequency_Hz) <= tolerance & ...
    abs(cache.KP - KP) <= tolerance & ...
    abs(cache.KI - KI) <= tolerance;
index = find(mask, 1, 'last');

if ~isempty(index)
    summary = cache(index, :);
    found = true;
end

end


function row = compactComparisonRow(name, summary, wasSimulated, usedCache)

row = table( ...
    name, summary.KP, summary.KI, wasSimulated, usedCache, ...
    summary.SimulationSucceeded, summary.SafetyPassed, ...
    summary.PerformanceObjective, summary.HighLoadMean_V, ...
    summary.LoadOnUndershoot_V, summary.LoadOffOvershoot_V, ...
    summary.LoadOnSettling_s, summary.LoadOffSettling_s, ...
    summary.HighLoadRipple_Vpp, summary.ILPeak_A, ...
    summary.PowerFactor, summary.THD_Percent, ...
    'VariableNames', { ...
        'Controller', 'KP', 'KI', 'WasSimulated', ...
        'UsedMeasuredCache', 'SimulationSucceeded', 'SafetyPassed', ...
        'PerformanceObjective', 'HighLoadMean_V', ...
        'LoadOnUndershoot_V', 'LoadOffOvershoot_V', ...
        'LoadOnSettling_s', 'LoadOffSettling_s', ...
        'HighLoadRipple_Vpp', 'ILPeak_A', ...
        'PowerFactor', 'THD_Percent'});

end


function row = createAbstainRow(inputSpec, name)

unused = inputSpec; %#ok<NASGU>
row = table( ...
    name, NaN, NaN, false, false, false, false, ...
    NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN, ...
    'VariableNames', { ...
        'Controller', 'KP', 'KI', 'WasSimulated', ...
        'UsedMeasuredCache', 'SimulationSucceeded', 'SafetyPassed', ...
        'PerformanceObjective', 'HighLoadMean_V', ...
        'LoadOnUndershoot_V', 'LoadOffOvershoot_V', ...
        'LoadOnSettling_s', 'LoadOffSettling_s', ...
        'HighLoadRipple_Vpp', 'ILPeak_A', ...
        'PowerFactor', 'THD_Percent'});

end


function combined = appendCompatible(existing, row)

if isempty(existing)
    combined = row;
    return;
end

if isequal(existing.Properties.VariableNames, row.Properties.VariableNames)
    combined = [existing; row];
    return;
end

shared = intersect( ...
    existing.Properties.VariableNames, row.Properties.VariableNames, ...
    'stable');
combined = [existing(:, shared); row(:, shared)];

end
