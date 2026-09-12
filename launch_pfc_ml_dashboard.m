function app = launch_pfc_ml_dashboard()
%LAUNCH_PFC_ML_DASHBOARD Clean light-theme PFC + ML workbench.
%
% Pages:
%   Tune                  - ML prediction + protected Simulink validation
%   Controller comparison - Baseline / strong fixed / ML comparison
%   ML operating map      - Prediction-only operating map
%
% Revision: 2.2.3-light
% MATLAB release target: R2025a

rootFolder = fileparts(mfilename('fullpath'));
exportFolder = fullfile(rootFolder, ...
    'pfc_ml_outputs_stage12_final_v210', 'workbench_exports');

%% ------------------------------------------------------------------------
%  Theme
% -------------------------------------------------------------------------
color = struct();
color.Canvas    = [0.965, 0.972, 0.980];
color.Surface   = [1.000, 1.000, 1.000];
color.Soft      = [0.945, 0.955, 0.968];
color.SoftBlue  = [0.925, 0.952, 0.985];
color.Ink       = [0.070, 0.085, 0.105];
color.Muted     = [0.340, 0.380, 0.430];
color.Blue      = [0.055, 0.330, 0.650];
color.Green     = [0.090, 0.500, 0.270];
color.Orange    = [0.820, 0.470, 0.080];
color.Red       = [0.760, 0.160, 0.180];
color.Line      = [0.820, 0.845, 0.875];
color.Rejected  = [0.890, 0.900, 0.915];

%% ------------------------------------------------------------------------
%  State
% -------------------------------------------------------------------------
currentPrediction = [];
currentResult = [];
currentComparison = [];
currentMap = [];
scenarioID = createScenarioID('GUI');

%% ------------------------------------------------------------------------
%  Figure and root layout
% -------------------------------------------------------------------------
fig = uifigure( ...
    'Name', 'PFC Controller Tuning Workbench', ...
    'Position', [35, 30, 1580, 900], ...
    'Color', color.Canvas);

main = uigridlayout(fig, [4, 1]);
main.RowHeight = {64, 42, '1x', 24};
main.Padding = [12, 10, 12, 8];
main.RowSpacing = 6;
main.BackgroundColor = color.Canvas;

% Header
header = uipanel(main, ...
    'BorderType', 'none', ...
    'BackgroundColor', color.Surface);
header.Layout.Row = 1;
headerGrid = uigridlayout(header, [1, 1]);
headerGrid.Padding = [16, 8, 16, 8];
headerGrid.BackgroundColor = color.Surface;
uilabel(headerGrid, ...
    'Text', 'PFC Controller Tuning Workbench', ...
    'FontSize', 22, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink, ...
    'VerticalAlignment', 'center');

% Custom navigation: avoids MATLAB dark tab-strip/theme issues.
navPanel = uipanel(main, ...
    'BorderType', 'none', ...
    'BackgroundColor', color.Canvas);
navPanel.Layout.Row = 2;
navGrid = uigridlayout(navPanel, [1, 4]);
navGrid.ColumnWidth = {120, 210, 180, '1x'};
navGrid.Padding = [0, 0, 0, 0];
navGrid.ColumnSpacing = 6;
navGrid.BackgroundColor = color.Canvas;

btnTune = uibutton(navGrid, 'push', ...
    'Text', 'Tune', ...
    'FontWeight', 'bold', ...
    'ButtonPushedFcn', @(~,~) showPage("Tune"));
btnCompare = uibutton(navGrid, 'push', ...
    'Text', 'Controller comparison', ...
    'FontWeight', 'bold', ...
    'ButtonPushedFcn', @(~,~) showPage("Compare"));
btnMap = uibutton(navGrid, 'push', ...
    'Text', 'ML operating map', ...
    'FontWeight', 'bold', ...
    'ButtonPushedFcn', @(~,~) showPage("Map"));

% Content host; pages overlap and are switched with Visible.
contentHost = uipanel(main, ...
    'BorderType', 'none', ...
    'BackgroundColor', color.Canvas);
contentHost.Layout.Row = 3;
contentGrid = uigridlayout(contentHost, [1, 1]);
contentGrid.Padding = [0, 0, 0, 0];
contentGrid.BackgroundColor = color.Canvas;

footer = uilabel(main, ...
    'Text', 'Ready.', ...
    'FontSize', 10, ...
    'FontColor', color.Muted);
footer.Layout.Row = 4;

%% ========================================================================
%  PAGE 1 - TUNE
% =========================================================================
tunePage = uipanel(contentGrid, ...
    'BorderType', 'none', ...
    'BackgroundColor', color.Canvas);
tunePage.Layout.Row = 1;
tunePage.Layout.Column = 1;

tuneGrid = uigridlayout(tunePage, [1, 3]);
tuneGrid.ColumnWidth = {300, '1x', 360};
tuneGrid.Padding = [0, 0, 0, 0];
tuneGrid.ColumnSpacing = 10;
tuneGrid.BackgroundColor = color.Canvas;

% ---------- Left card: operating condition ----------
inputPanel = uipanel(tuneGrid, ...
    'BorderType', 'line', ...
    'BackgroundColor', color.Surface);
inputGrid = uigridlayout(inputPanel, [12, 2]);
inputGrid.RowHeight = {34, 31, 31, 31, 31, 31, 31, 31, 14, 42, 46, 36};
inputGrid.ColumnWidth = {132, '1x'};
inputGrid.Padding = [12, 8, 12, 10];
inputGrid.RowSpacing = 7;
inputGrid.BackgroundColor = color.Surface;

inputTitle = uilabel(inputGrid, ...
    'Text', 'Operating condition', ...
    'FontSize', 15, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink);
inputTitle.Layout.Row = 1;
inputTitle.Layout.Column = [1, 2];

addInputLabel(inputGrid, 2, 'Scenario preset', color);
preset = uidropdown(inputGrid, ...
    'Items', {'Custom', 'Low line / heavy load', ...
        'Nominal full load', 'High line / light load'}, ...
    'Value', 'Custom', ...
    'ValueChangedFcn', @onPresetChanged);
place(preset, 2, 2);
styleField(preset, color);

addInputLabel(inputGrid, 3, 'Input voltage', color);
vin = uieditfield(inputGrid, 'numeric', ...
    'Limits', [180, 265], 'Value', 212, ...
    'ValueDisplayFormat', '%.1f VAC');
place(vin, 3, 2);
styleField(vin, color);

addInputLabel(inputGrid, 4, 'Pre-load', color);
preLoad = uieditfield(inputGrid, 'numeric', ...
    'Limits', [200, 500], 'Value', 365, ...
    'ValueDisplayFormat', '%.1f W');
place(preLoad, 4, 2);
styleField(preLoad, color);

addInputLabel(inputGrid, 5, 'High load', color);
highLoad = uieditfield(inputGrid, 'numeric', ...
    'Limits', [900, 1400], 'Value', 1275, ...
    'ValueDisplayFormat', '%.1f W');
place(highLoad, 5, 2);
styleField(highLoad, color);

addInputLabel(inputGrid, 6, 'Boost inductance', color);
inductance = uieditfield(inputGrid, 'numeric', ...
    'Limits', [248.8, 373.2], 'Value', 318, ...
    'ValueDisplayFormat', '%.1f uH');
place(inductance, 6, 2);
styleField(inductance, color);

addInputLabel(inputGrid, 7, 'DC bus capacitance', color);
capacitance = uieditfield(inputGrid, 'numeric', ...
    'Limits', [952, 1496], 'Value', 1325, ...
    'ValueDisplayFormat', '%.1f uF');
place(capacitance, 7, 2);
styleField(capacitance, color);

addInputLabel(inputGrid, 8, 'Line frequency', color);
frequency = uieditfield(inputGrid, 'numeric', ...
    'Limits', [47, 53], 'Value', 50.4, ...
    'ValueDisplayFormat', '%.1f Hz');
place(frequency, 8, 2);
styleField(frequency, color);

% Rows 9 deliberately blank: no domain note, no online-update checkbox,
% no workflow explanation text.

predictButton = uibutton(inputGrid, 'push', ...
    'Text', 'Predict gains', ...
    'FontWeight', 'bold', ...
    'BackgroundColor', color.SoftBlue, ...
    'FontColor', color.Blue, ...
    'ButtonPushedFcn', @onPredict);
predictButton.Layout.Row = 10;
predictButton.Layout.Column = [1, 2];

validateButton = uibutton(inputGrid, 'push', ...
    'Text', 'Validate in Simulink', ...
    'FontWeight', 'bold', ...
    'BackgroundColor', color.Blue, ...
    'FontColor', [1, 1, 1], ...
    'ButtonPushedFcn', @onValidate);
validateButton.Layout.Row = 11;
validateButton.Layout.Column = [1, 2];

buttonGrid = uigridlayout(inputGrid, [1, 2]);
buttonGrid.Layout.Row = 12;
buttonGrid.Layout.Column = [1, 2];
buttonGrid.Padding = [0, 0, 0, 0];
buttonGrid.ColumnSpacing = 8;
buttonGrid.BackgroundColor = color.Surface;

resetButton = uibutton(buttonGrid, 'push', ...
    'Text', 'Reset', ...
    'BackgroundColor', color.Soft, ...
    'FontColor', color.Ink, ...
    'ButtonPushedFcn', @onReset);
exportButton = uibutton(buttonGrid, 'push', ...
    'Text', 'Export result', ...
    'Enable', 'off', ...
    'BackgroundColor', color.Soft, ...
    'FontColor', color.Ink, ...
    'ButtonPushedFcn', @onExport);

% ---------- Center card: selected controller and plots ----------
centerPanel = uipanel(tuneGrid, ...
    'BorderType', 'none', ...
    'BackgroundColor', color.Canvas);
centerGrid = uigridlayout(centerPanel, [3, 1]);
centerGrid.RowHeight = {132, '1x', '1x'};
centerGrid.Padding = [0, 0, 0, 0];
centerGrid.RowSpacing = 10;
centerGrid.BackgroundColor = color.Canvas;

selectedPanel = uipanel(centerGrid, ...
    'BorderType', 'line', ...
    'BackgroundColor', color.Surface);
selectedGrid = uigridlayout(selectedPanel, [3, 6]);
selectedGrid.RowHeight = {28, 22, 52};
selectedGrid.ColumnWidth = {'1x', '1x', '1x', '1x', '1x', '1x'};
selectedGrid.Padding = [10, 7, 10, 8];
selectedGrid.ColumnSpacing = 4;
selectedGrid.BackgroundColor = color.Surface;

selectedTitle = uilabel(selectedGrid, ...
    'Text', 'Selected controller', ...
    'FontSize', 15, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink);
selectedTitle.Layout.Row = 1;
selectedTitle.Layout.Column = [1, 6];

decisionValue = addMetric(selectedGrid, 1, 'Decision', 'Waiting', color);
kpValue = addMetric(selectedGrid, 2, 'Selected KP', '-', color);
kiValue = addMetric(selectedGrid, 3, 'Selected KI', '-', color);
confidenceValue = addMetric(selectedGrid, 4, 'ML P(feasible)', '-', color);
predictedJValue = addMetric(selectedGrid, 5, 'Predicted J', '-', color);
measuredJValue = addMetric(selectedGrid, 6, 'Measured J', '-', color);

jAxes = uiaxes(centerGrid);
styleAxes(jAxes, 'Predicted vs measured objective', 'Objective J', color);
emptyAxes(jAxes, 'Run Predict gains', color);

safetyAxes = uiaxes(centerGrid);
styleAxes(safetyAxes, 'Measured constraint usage', 'Usage / limit', color);
safetyAxes.YLim = [0, 1.2];
yline(safetyAxes, 1, '--', 'Limit', ...
    'Color', color.Red, 'LineWidth', 1.2);
emptyAxes(safetyAxes, 'Run Simulink validation', color);

% ---------- Right card: measured limits, custom labels (no uitable) ----------
metricPanel = uipanel(tuneGrid, ...
    'BorderType', 'line', ...
    'BackgroundColor', color.Surface);
metricGrid = uigridlayout(metricPanel, [8, 4]);
metricGrid.RowHeight = {34, 30, 34, 34, 34, 34, 34, 34};
metricGrid.ColumnWidth = {125, 82, 90, '1x'};
metricGrid.Padding = [10, 8, 10, 10];
metricGrid.RowSpacing = 2;
metricGrid.ColumnSpacing = 2;
metricGrid.BackgroundColor = color.Surface;

metricTitle = uilabel(metricGrid, ...
    'Text', 'Measured Simulink limits', ...
    'FontSize', 15, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink);
metricTitle.Layout.Row = 1;
metricTitle.Layout.Column = [1, 4];

makeHeaderCell(metricGrid, 2, 1, 'Metric', color);
makeHeaderCell(metricGrid, 2, 2, 'Measured', color);
makeHeaderCell(metricGrid, 2, 3, 'Limit', color);
makeHeaderCell(metricGrid, 2, 4, 'Status', color);

metricNames = { ...
    'High-load Vout'; ...
    'Global Vout min'; ...
    'Global Vout max'; ...
    'Inductor peak'; ...
    'Power factor'; ...
    'THD'};
metricLimits = { ...
    '392-408 V'; ...
    '>= 300 V'; ...
    '<= 431 V'; ...
    '<= 16 A'; ...
    '>= 0.95'; ...
    '<= 15 %'};
metricMeasured = cell(6,1);
metricStatus = cell(6,1);

for i = 1:6
    row = i + 2;
    makeBodyCell(metricGrid, row, 1, metricNames{i}, 'left', color);
    metricMeasured{i} = makeBodyCell(metricGrid, row, 2, '-', 'center', color);
    makeBodyCell(metricGrid, row, 3, metricLimits{i}, 'center', color);
    metricStatus{i} = makeBodyCell(metricGrid, row, 4, '-', 'center', color);
end

%% ========================================================================
%  PAGE 2 - CONTROLLER COMPARISON
% =========================================================================
comparePage = uipanel(contentGrid, ...
    'BorderType', 'none', ...
    'BackgroundColor', color.Canvas, ...
    'Visible', 'off');
comparePage.Layout.Row = 1;
comparePage.Layout.Column = 1;

compareGrid = uigridlayout(comparePage, [2, 2]);
compareGrid.RowHeight = {'1x', 255};
compareGrid.ColumnWidth = {310, '1x'};
compareGrid.Padding = [0, 0, 0, 0];
compareGrid.RowSpacing = 10;
compareGrid.ColumnSpacing = 10;
compareGrid.BackgroundColor = color.Canvas;

compareControlPanel = uipanel(compareGrid, ...
    'BorderType', 'line', ...
    'BackgroundColor', color.Surface);
compareControlPanel.Layout.Row = [1, 2];
compareControlPanel.Layout.Column = 1;
compareControlGrid = uigridlayout(compareControlPanel, [7, 1]);
compareControlGrid.RowHeight = {34, 88, 34, 34, 56, '1x', 44};
compareControlGrid.Padding = [12, 8, 12, 10];
compareControlGrid.BackgroundColor = color.Surface;

uilabel(compareControlGrid, ...
    'Text', 'Controller comparison', ...
    'FontSize', 15, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink);
compareScenarioLabel = uilabel(compareControlGrid, ...
    'Text', scenarioSummary(), ...
    'WordWrap', 'on', ...
    'FontColor', color.Ink, ...
    'VerticalAlignment', 'top');
uilabel(compareControlGrid, ...
    'Text', 'Baseline PI      KP 0.010   KI 0.80', ...
    'FontColor', color.Muted);
uilabel(compareControlGrid, ...
    'Text', 'Strong fixed PI  KP 0.150   KI 12.00', ...
    'FontColor', color.Muted);
compareSummary = uilabel(compareControlGrid, ...
    'Text', 'No comparison has been run.', ...
    'WordWrap', 'on', ...
    'FontColor', color.Ink, ...
    'VerticalAlignment', 'top');
uilabel(compareControlGrid, 'Text', '');
compareButton = uibutton(compareControlGrid, 'push', ...
    'Text', 'Run controller comparison', ...
    'BackgroundColor', color.Blue, ...
    'FontColor', [1, 1, 1], ...
    'FontWeight', 'bold', ...
    'ButtonPushedFcn', @onCompare);

comparisonAxes = uiaxes(compareGrid);
comparisonAxes.Layout.Row = 1;
comparisonAxes.Layout.Column = 2;
styleAxes(comparisonAxes, 'Measured objective by controller', 'Objective J', color);
emptyAxes(comparisonAxes, 'Run controller comparison', color);

comparisonPanel = uipanel(compareGrid, ...
    'BorderType', 'line', ...
    'BackgroundColor', color.Surface);
comparisonPanel.Layout.Row = 2;
comparisonPanel.Layout.Column = 2;
comparisonGrid = uigridlayout(comparisonPanel, [5, 9]);
comparisonGrid.RowHeight = {30, 28, 52, 52, 52};
comparisonGrid.ColumnWidth = {145, 75, 75, 80, 88, 86, 80, 80, '1x'};
comparisonGrid.Padding = [8, 6, 8, 8];
comparisonGrid.RowSpacing = 2;
comparisonGrid.ColumnSpacing = 2;
comparisonGrid.BackgroundColor = color.Surface;

comparisonTitle = uilabel(comparisonGrid, ...
    'Text', 'Measured Simulink comparison', ...
    'FontSize', 14, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink);
comparisonTitle.Layout.Row = 1;
comparisonTitle.Layout.Column = [1, 9];

comparisonHeaders = {'Controller','KP','KI','J','Vout','IL peak','PF','THD','Status'};
for c = 1:numel(comparisonHeaders)
    makeHeaderCell(comparisonGrid, 2, c, comparisonHeaders{c}, color);
end

comparisonCells = cell(3,9);
for r = 1:3
    for c = 1:9
        align = 'center';
        if c == 1
            align = 'left';
        end
        comparisonCells{r,c} = makeBodyCell(comparisonGrid, r+2, c, '-', align, color);
    end
end

%% ========================================================================
%  PAGE 3 - ML OPERATING MAP
% =========================================================================
mapPage = uipanel(contentGrid, ...
    'BorderType', 'none', ...
    'BackgroundColor', color.Canvas, ...
    'Visible', 'off');
mapPage.Layout.Row = 1;
mapPage.Layout.Column = 1;

mapGrid = uigridlayout(mapPage, [1, 2]);
mapGrid.ColumnWidth = {310, '1x'};
mapGrid.Padding = [0, 0, 0, 0];
mapGrid.ColumnSpacing = 10;
mapGrid.BackgroundColor = color.Canvas;

mapControlPanel = uipanel(mapGrid, ...
    'BorderType', 'line', ...
    'BackgroundColor', color.Surface);
mapControlGrid = uigridlayout(mapControlPanel, [8, 1]);
mapControlGrid.RowHeight = {34, 88, 28, 36, 44, 50, '1x', 40};
mapControlGrid.Padding = [12, 8, 12, 10];
mapControlGrid.BackgroundColor = color.Surface;

uilabel(mapControlGrid, ...
    'Text', 'ML operating map', ...
    'FontSize', 15, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink);
mapScenarioLabel = uilabel(mapControlGrid, ...
    'Text', mapFixedSummary(), ...
    'WordWrap', 'on', ...
    'FontColor', color.Ink, ...
    'VerticalAlignment', 'top');
uilabel(mapControlGrid, ...
    'Text', 'Displayed quantity', ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink);
mapMetric = uidropdown(mapControlGrid, ...
    'Items', {'Recommended KP', 'Recommended KI', ...
        'Predicted objective J', 'P(feasible)'}, ...
    'Value', 'Recommended KP', ...
    'ValueChangedFcn', @onMapMetricChanged);
styleField(mapMetric, color);
mapButton = uibutton(mapControlGrid, 'push', ...
    'Text', 'Generate operating map', ...
    'BackgroundColor', color.Blue, ...
    'FontColor', [1, 1, 1], ...
    'FontWeight', 'bold', ...
    'ButtonPushedFcn', @onBuildMap);
mapStatus = uilabel(mapControlGrid, ...
    'Text', 'No map generated.', ...
    'WordWrap', 'on', ...
    'FontColor', color.Muted, ...
    'VerticalAlignment', 'top');
uilabel(mapControlGrid, 'Text', '');
mapExportButton = uibutton(mapControlGrid, 'push', ...
    'Text', 'Export map CSV', ...
    'Enable', 'off', ...
    'BackgroundColor', color.Soft, ...
    'FontColor', color.Ink, ...
    'ButtonPushedFcn', @onMapExport);

mapAxes = uiaxes(mapGrid);
styleAxes(mapAxes, 'ML operating map - prediction only', 'Input voltage (VAC)', color);
mapAxes.XLabel.String = 'High load (W)';
emptyAxes(mapAxes, 'Generate operating map', color);

%% ------------------------------------------------------------------------
%  App handle and initial page
% -------------------------------------------------------------------------
app = struct();
app.Figure = fig;
app.Revision = "2.2.3-light";
app.SimulationOnly = true;
app.RealDataOnly = true;

showPage("Tune");

%% ========================================================================
%  NAVIGATION
% =========================================================================
    function showPage(pageName)
        tunePage.Visible = 'off';
        comparePage.Visible = 'off';
        mapPage.Visible = 'off';

        setNavButton(btnTune, false, color);
        setNavButton(btnCompare, false, color);
        setNavButton(btnMap, false, color);

        switch string(pageName)
            case "Tune"
                tunePage.Visible = 'on';
                setNavButton(btnTune, true, color);
            case "Compare"
                comparePage.Visible = 'on';
                setNavButton(btnCompare, true, color);
                syncScenarioLabels();
            case "Map"
                mapPage.Visible = 'on';
                setNavButton(btnMap, true, color);
                syncScenarioLabels();
        end
        drawnow;
    end

%% ========================================================================
%  CALLBACKS
% =========================================================================
    function onPresetChanged(~, ~)
        switch string(preset.Value)
            case "Low line / heavy load"
                vin.Value = 188;
                preLoad.Value = 425;
                highLoad.Value = 1380;
                inductance.Value = 270;
                capacitance.Value = 1050;
                frequency.Value = 48.3;
            case "Nominal full load"
                vin.Value = 230;
                preLoad.Value = 300;
                highLoad.Value = 1400;
                inductance.Value = 311;
                capacitance.Value = 1360;
                frequency.Value = 50;
            case "High line / light load"
                vin.Value = 260;
                preLoad.Value = 275;
                highLoad.Value = 1000;
                inductance.Value = 345;
                capacitance.Value = 1100;
                frequency.Value = 51.8;
            otherwise
                return;
        end

        scenarioID = createScenarioID('GUI_PRESET');
        syncScenarioLabels();
        footer.Text = 'Preset loaded.';
    end

    function onPredict(~, ~)
        progress = [];
        try
            setBusy(true);
            progress = uiprogressdlg(fig, ...
                'Title', 'ML prediction', ...
                'Message', 'Searching candidate KP/KI gains...', ...
                'Indeterminate', 'on');

            currentPrediction = predict_pfc_stage12_gains(readScenario());
            currentResult = [];
            updatePrediction(currentPrediction);
            exportButton.Enable = 'on';

            closeProgress(progress);
            setBusy(false);
        catch problem
            closeProgress(progress);
            setBusy(false);
            showProblem(problem);
        end
    end

    function onValidate(~, ~)
        progress = [];
        try
            setBusy(true);
            spec = readScenario();
            spec.VerifyInSimulink = true;
            % Online update remains enabled, but the checkbox was removed
            % from the simplified UI. Only real Simulink-labelled rows are used.
            spec.UpdateModel = true;
            spec.SaveArtifacts = false;

            progress = uiprogressdlg(fig, ...
                'Title', 'Simulink validation', ...
                'Message', 'Running protected switching-Simulink case...', ...
                'Indeterminate', 'on', ...
                'Cancelable', 'off');

            currentResult = run_pfc_stage12_final_hybrid_tuner(spec);
            currentPrediction = currentResult.InitialPrediction;
            updateValidatedResult(currentResult);
            exportButton.Enable = 'on';

            closeProgress(progress);
            setBusy(false);
        catch problem
            closeProgress(progress);
            setBusy(false);
            showProblem(problem);
        end
    end

    function onCompare(~, ~)
        progress = [];
        try
            setBusy(true);
            syncScenarioLabels();
            progress = uiprogressdlg(fig, ...
                'Title', 'Controller comparison', ...
                'Message', 'Running required protected Simulink cases...', ...
                'Indeterminate', 'on', ...
                'Cancelable', 'off');

            currentComparison = compare_pfc_stage12_controllers(readScenario());
            updateComparison(currentComparison);
            exportButton.Enable = 'on';

            footer.Text = sprintf( ...
                'Comparison complete. New runs: %d | measured cache: %d', ...
                currentComparison.NewRealSimulations, ...
                currentComparison.MeasuredCacheUses);

            closeProgress(progress);
            setBusy(false);
        catch problem
            closeProgress(progress);
            setBusy(false);
            showProblem(problem);
        end
    end

    function onBuildMap(~, ~)
        progress = [];
        try
            setBusy(true);
            syncScenarioLabels();
            progress = uiprogressdlg(fig, ...
                'Title', 'ML operating map', ...
                'Message', 'Evaluating prediction grid...', ...
                'Indeterminate', 'on');

            currentMap = build_pfc_stage12_operating_map(readScenario());
            plotOperatingMap();
            mapExportButton.Enable = 'on';

            footer.Text = 'Operating map generated. Prediction only; Simulink runs = 0.';

            closeProgress(progress);
            setBusy(false);
        catch problem
            closeProgress(progress);
            setBusy(false);
            showProblem(problem);
        end
    end

    function onMapMetricChanged(~, ~)
        if ~isempty(currentMap)
            plotOperatingMap();
        end
    end

    function onMapExport(~, ~)
        try
            if isempty(currentMap)
                return;
            end
            ensureExportFolder();
            stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
            file = fullfile(exportFolder, ...
                ['pfc_ml_operating_map_prediction_' stamp '.csv']);
            writetable(currentMap.PointTable, file);
            footer.Text = ['Map exported: ' file];
            uialert(fig, ['Prediction map saved:' newline file], ...
                'Export completed', 'Icon', 'success');
        catch problem
            showProblem(problem);
        end
    end

    function onReset(~, ~)
        preset.Value = 'Custom';
        scenarioID = createScenarioID('GUI');
        vin.Value = 212;
        preLoad.Value = 365;
        highLoad.Value = 1275;
        inductance.Value = 318;
        capacitance.Value = 1325;
        frequency.Value = 50.4;
        currentPrediction = [];
        currentResult = [];
        resetTuneView();
        syncScenarioLabels();
        footer.Text = 'Reset completed.';
    end

    function onExport(~, ~)
        try
            ensureExportFolder();
            stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
            imageFile = fullfile(exportFolder, ['pfc_ml_workbench_' stamp '.png']);
            exportapp(fig, imageFile);
            files = string(imageFile);

            if ~isempty(currentResult) && ~isempty(currentResult.SelectedResult)
                file = fullfile(exportFolder, ['pfc_ml_validated_result_' stamp '.csv']);
                writetable(currentResult.SelectedResult, file);
                files(end+1) = string(file);
            elseif ~isempty(currentPrediction)
                file = fullfile(exportFolder, ['pfc_ml_prediction_' stamp '.csv']);
                writetable(currentPrediction.ResultTable, file);
                files(end+1) = string(file);
            end

            if ~isempty(currentComparison)
                file = fullfile(exportFolder, ['pfc_ml_controller_comparison_' stamp '.csv']);
                writetable(currentComparison.ComparisonTable, file);
                files(end+1) = string(file);
            end

            footer.Text = ['Exported: ' imageFile];
            uialert(fig, strjoin(files, newline), ...
                'Export completed', 'Icon', 'success');
        catch problem
            showProblem(problem);
        end
    end

%% ========================================================================
%  VIEW UPDATES
% =========================================================================
    function updatePrediction(prediction)
        decisionValue.Text = sentenceCase(prediction.Decision);
        confidenceValue.Text = sprintf('%.1f %%', ...
            100 .* prediction.FeasibilityProbability);
        predictedJValue.Text = numberText(prediction.PredictedObjective, 5);
        measuredJValue.Text = '-';

        if prediction.Decision == "RECOMMEND"
            kpValue.Text = sprintf('%.6f', prediction.KP);
            kiValue.Text = sprintf('%.5f', prediction.KI);
            decisionValue.FontColor = color.Green;
            plotObjective(prediction.PredictedObjective, NaN);
            footer.Text = sprintf('ML recommendation: KP %.6f | KI %.5f', ...
                prediction.KP, prediction.KI);
        else
            kpValue.Text = '-';
            kiValue.Text = '-';
            decisionValue.FontColor = color.Orange;
            plotObjective(NaN, NaN);
            footer.Text = ['ML abstained: ' char(prediction.Reason)];
        end

        resetMetrics();
        cla(safetyAxes);
        styleAxes(safetyAxes, 'Measured constraint usage', 'Usage / limit', color);
        safetyAxes.YLim = [0, 1.2];
        yline(safetyAxes, 1, '--', 'Limit', ...
            'Color', color.Red, 'LineWidth', 1.2);
        emptyAxes(safetyAxes, 'Run Simulink validation', color);
    end

    function updateValidatedResult(result)
        prediction = result.InitialPrediction;
        confidenceValue.Text = sprintf('%.1f %%', ...
            100 .* prediction.FeasibilityProbability);
        predictedJValue.Text = numberText(prediction.PredictedObjective, 5);

        if result.ResultVerified && ~isempty(result.SelectedResult)
            measured = result.SelectedResult;
            decisionValue.Text = 'Validated';
            decisionValue.FontColor = color.Green;
            kpValue.Text = sprintf('%.6f', measured.KP);
            kiValue.Text = sprintf('%.5f', measured.KI);
            measuredJValue.Text = sprintf('%.5f', measured.PerformanceObjective);

            plotObjective(prediction.PredictedObjective, measured.PerformanceObjective);
            plotSafetyUsage(measured);
            updateMetrics(measured);

            footer.Text = sprintf( ...
                'Validated: KP %.6f | KI %.5f | measured J %.5f', ...
                measured.KP, measured.KI, measured.PerformanceObjective);
        else
            decisionValue.Text = 'Not validated';
            decisionValue.FontColor = color.Red;
            measuredJValue.Text = '-';
            footer.Text = 'No feasible controller was confirmed by Simulink.';
        end
    end

    function updateComparison(output)
        data = output.ComparisonTable;

        cla(comparisonAxes);
        styleAxes(comparisonAxes, 'Measured objective by controller', 'Objective J', color);

        values = data.PerformanceObjective;
        labels = categorical(cellstr(data.Controller));
        bars = bar(comparisonAxes, labels, values, 0.55);
        bars.FaceColor = 'flat';
        bars.CData = repmat(color.Muted, height(data), 1);

        for index = 1:height(data)
            if data.Controller(index) == output.BestController
                bars.CData(index,:) = color.Green;
            elseif data.Controller(index) == "ML recommendation"
                bars.CData(index,:) = color.Blue;
            end
        end

        finiteValues = values(isfinite(values));
        if ~isempty(finiteValues)
            comparisonAxes.YLim = [0, max(0.12, 1.22 .* max(finiteValues))];
            addBarLabels(comparisonAxes, values);
        end

        updateComparisonGrid(data);
        compareSummary.Text = sprintf( ...
            'Best measured: %s\nImprovement vs baseline: %.2f %%', ...
            char(output.BestController), output.ImprovementVsBaseline_Percent);
    end

    function plotOperatingMap()
        switch string(mapMetric.Value)
            case "Recommended KP"
                values = currentMap.KP;
                titleValue = 'Recommended KP';
                unit = 'KP';
            case "Recommended KI"
                values = currentMap.KI;
                titleValue = 'Recommended KI';
                unit = 'KI';
            case "Predicted objective J"
                values = currentMap.PredictedObjective;
                titleValue = 'Predicted objective J';
                unit = 'Predicted J';
            otherwise
                values = currentMap.FeasibilityProbability;
                titleValue = 'Predicted feasibility';
                unit = 'P(feasible)';
        end

        recommendMask = currentMap.Decision == "RECOMMEND";
        visibleMask = recommendMask & isfinite(values);
        displayValues = values;
        displayValues(~visibleMask) = NaN;

        cla(mapAxes);
        mapAxes.Color = color.Rejected;
        mapImage = imagesc(mapAxes, currentMap.HighLoadValues, ...
            currentMap.VinValues, displayValues);
        mapImage.AlphaData = double(visibleMask);
        mapAxes.YDir = 'normal';
        mapAxes.XLabel.String = 'High load (W)';
        mapAxes.YLabel.String = 'Input voltage (VAC)';
        mapAxes.Title.String = [titleValue ' - prediction only'];
        mapAxes.Title.FontWeight = 'bold';
        mapAxes.Box = 'on';
        mapAxes.Layer = 'top';
        mapAxes.XTick = currentMap.HighLoadValues(1:2:end);
        mapAxes.XTickLabel = compose('%.0f', currentMap.HighLoadValues(1:2:end));
        mapAxes.YTick = currentMap.VinValues(1:2:end);
        mapAxes.YTickLabel = compose('%.0f', currentMap.VinValues(1:2:end));
        colormap(mapAxes, parula(256));
        colorbar(mapAxes);

        hold(mapAxes, 'on');
        [rejectedRow, rejectedColumn] = find(~recommendMask);
        if ~isempty(rejectedRow)
            rejectedX = currentMap.HighLoadValues(rejectedColumn);
            rejectedY = currentMap.VinValues(rejectedRow);
            plot(mapAxes, rejectedX, rejectedY, 'x', ...
                'Color', color.Ink, 'MarkerSize', 5, 'LineWidth', 0.8);
        end
        plot(mapAxes, highLoad.Value, vin.Value, 'o', ...
            'Color', color.Ink, ...
            'MarkerFaceColor', [1,1,1], ...
            'MarkerSize', 8, ...
            'LineWidth', 1.5);
        hold(mapAxes, 'off');

        mapStatus.Text = sprintf('%s | Recommend %d/%d | x = ABSTAIN', ...
            unit, nnz(recommendMask), numel(recommendMask));
    end

    function plotObjective(predictedValue, measuredValue)
        cla(jAxes);
        styleAxes(jAxes, 'Predicted vs measured objective', 'Objective J', color);

        if isfinite(predictedValue) && isfinite(measuredValue)
            values = [predictedValue, measuredValue];
            bars = bar(jAxes, categorical({'ML prediction','Simulink'}), values, 0.54);
            bars.FaceColor = 'flat';
            bars.CData = [color.Blue; color.Green];
            jAxes.YLim = [0, max(0.10, 1.24 .* max(values))];
            addBarLabels(jAxes, values);
        elseif isfinite(predictedValue)
            bars = bar(jAxes, categorical({'ML prediction'}), predictedValue, 0.44);
            bars.FaceColor = color.Blue;
            jAxes.YLim = [0, max(0.10, 1.24 .* predictedValue)];
            addBarLabels(jAxes, predictedValue);
        else
            emptyAxes(jAxes, 'ML abstained', color);
        end
    end

    function plotSafetyUsage(measured)
        usage = [ ...
            abs(measured.HighLoadMean_V - 400) ./ 8; ...
            measured.ILPeak_A ./ 16; ...
            max(0, (1 - measured.PowerFactor) ./ 0.05); ...
            measured.THD_Percent ./ 15; ...
            max(0, (measured.GlobalVoutMaximum_V - 400) ./ 31)]';

        labels = categorical({'Vout error','IL peak','PF deficit','THD','Vout max'});
        cla(safetyAxes);
        styleAxes(safetyAxes, 'Measured constraint usage', 'Usage / limit', color);
        bars = bar(safetyAxes, labels, usage, 0.58);
        bars.FaceColor = color.Green;
        safetyAxes.YLim = [0, max(1.2, 1.15 .* max(usage))];
        yline(safetyAxes, 1, '--', 'Limit', ...
            'Color', color.Red, 'LineWidth', 1.2);
    end

%% ========================================================================
%  METRIC / COMPARISON GRIDS
% =========================================================================
    function resetMetrics()
        for k = 1:6
            metricMeasured{k}.Text = '-';
            metricStatus{k}.Text = '-';
            metricStatus{k}.FontColor = color.Muted;
        end
    end

    function updateMetrics(measured)
        values = { ...
            sprintf('%.3f V', measured.HighLoadMean_V); ...
            sprintf('%.3f V', measured.GlobalVoutMinimum_V); ...
            sprintf('%.3f V', measured.GlobalVoutMaximum_V); ...
            sprintf('%.3f A', measured.ILPeak_A); ...
            sprintf('%.5f', measured.PowerFactor); ...
            sprintf('%.3f %%', measured.THD_Percent)};

        passed = [ ...
            measured.HighLoadMean_V >= 392 && measured.HighLoadMean_V <= 408; ...
            measured.GlobalVoutMinimum_V >= 300; ...
            measured.GlobalVoutMaximum_V <= 431; ...
            measured.ILPeak_A <= 16; ...
            measured.PowerFactor >= 0.95; ...
            measured.THD_Percent <= 15];

        for k = 1:6
            metricMeasured{k}.Text = values{k};
            if passed(k)
                metricStatus{k}.Text = 'PASS';
                metricStatus{k}.FontColor = color.Green;
            else
                metricStatus{k}.Text = 'FAIL';
                metricStatus{k}.FontColor = color.Red;
            end
            metricStatus{k}.FontWeight = 'bold';
        end
    end

    function updateComparisonGrid(data)
        for r = 1:3
            for c = 1:9
                comparisonCells{r,c}.Text = '-';
                comparisonCells{r,c}.FontColor = color.Ink;
                comparisonCells{r,c}.FontWeight = 'normal';
            end
        end

        rowsToShow = min(3, height(data));
        for r = 1:rowsToShow
            statusPass = data.SimulationSucceeded(r) && data.SafetyPassed(r);
            rowValues = { ...
                char(data.Controller(r)), ...
                numberText(data.KP(r), 6), ...
                numberText(data.KI(r), 5), ...
                numberText(data.PerformanceObjective(r), 5), ...
                unitText(data.HighLoadMean_V(r), 'V', 2), ...
                unitText(data.ILPeak_A(r), 'A', 2), ...
                numberText(data.PowerFactor(r), 4), ...
                unitText(data.THD_Percent(r), '%', 2), ...
                passText(statusPass)};

            for c = 1:9
                comparisonCells{r,c}.Text = rowValues{c};
            end

            comparisonCells{r,1}.FontWeight = 'bold';
            comparisonCells{r,9}.FontWeight = 'bold';
            if statusPass
                comparisonCells{r,9}.FontColor = color.Green;
            else
                comparisonCells{r,9}.FontColor = color.Red;
            end
        end
    end

%% ========================================================================
%  SCENARIO / GENERAL HELPERS
% =========================================================================
    function spec = readScenario()
        if highLoad.Value - preLoad.Value < 500
            error('PFCMLDashboard:LoadStepTooSmall', ...
                'High load minus pre-load must be at least 500 W.');
        end

        if strlength(strtrim(string(scenarioID))) == 0
            scenarioID = createScenarioID('GUI');
        end

        spec = struct();
        spec.ScenarioID = string(scenarioID);
        spec.Vin_RMS = vin.Value;
        spec.Pload_Pre_W = preLoad.Value;
        spec.Pload_High_W = highLoad.Value;
        spec.BoostInductance_uH = inductance.Value;
        spec.DCBusCapacitance_uF = capacitance.Value;
        spec.LineFrequency_Hz = frequency.Value;
    end

    function value = scenarioSummary()
        value = sprintf(['Vin %.1f VAC\nLoad %.0f -> %.0f W\n' ...
            'L %.1f uH | C %.1f uF | %.1f Hz'], ...
            vin.Value, preLoad.Value, highLoad.Value, ...
            inductance.Value, capacitance.Value, frequency.Value);
    end

    function value = mapFixedSummary()
        value = sprintf(['Fixed while Vin / high load vary:\n' ...
            'Pre-load %.0f W\nL %.1f uH | C %.1f uF | %.1f Hz'], ...
            preLoad.Value, inductance.Value, capacitance.Value, frequency.Value);
    end

    function syncScenarioLabels()
        compareScenarioLabel.Text = scenarioSummary();
        mapScenarioLabel.Text = mapFixedSummary();
    end

    function setBusy(isBusy)
        state = 'on';
        if isBusy
            state = 'off';
        end
        predictButton.Enable = state;
        validateButton.Enable = state;
        compareButton.Enable = state;
        mapButton.Enable = state;
        resetButton.Enable = state;
    end

    function resetTuneView()
        decisionValue.Text = 'Waiting';
        decisionValue.FontColor = color.Blue;
        kpValue.Text = '-';
        kiValue.Text = '-';
        confidenceValue.Text = '-';
        predictedJValue.Text = '-';
        measuredJValue.Text = '-';
        resetMetrics();

        cla(jAxes);
        styleAxes(jAxes, 'Predicted vs measured objective', 'Objective J', color);
        emptyAxes(jAxes, 'Run Predict gains', color);

        cla(safetyAxes);
        styleAxes(safetyAxes, 'Measured constraint usage', 'Usage / limit', color);
        safetyAxes.YLim = [0, 1.2];
        yline(safetyAxes, 1, '--', 'Limit', ...
            'Color', color.Red, 'LineWidth', 1.2);
        emptyAxes(safetyAxes, 'Run Simulink validation', color);

        exportButton.Enable = 'off';
    end

    function ensureExportFolder()
        if ~isfolder(exportFolder)
            mkdir(exportFolder);
        end
    end

    function showProblem(problem)
        footer.Text = ['Error: ' problem.message];
        uialert(fig, getReport(problem, 'basic', 'hyperlinks', 'off'), ...
            'PFC workbench error', 'Icon', 'error');
    end
end

%% ========================================================================
%  LOCAL FUNCTIONS
% =========================================================================
function addInputLabel(parent, row, textValue, color)
label = uilabel(parent, ...
    'Text', textValue, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink);
place(label, row, 1);
end

function place(component, row, column)
component.Layout.Row = row;
component.Layout.Column = column;
end

function styleField(control, color)
if isprop(control, 'BackgroundColor')
    control.BackgroundColor = [1, 1, 1];
end
if isprop(control, 'FontColor')
    control.FontColor = color.Ink;
end
end

function label = addMetric(parent, column, name, initialValue, color)
nameLabel = uilabel(parent, ...
    'Text', name, ...
    'HorizontalAlignment', 'center', ...
    'FontSize', 10, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink);
nameLabel.Layout.Row = 2;
nameLabel.Layout.Column = column;

label = uilabel(parent, ...
    'Text', initialValue, ...
    'HorizontalAlignment', 'center', ...
    'FontSize', 18, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Blue);
label.Layout.Row = 3;
label.Layout.Column = column;
end

function label = makeHeaderCell(parent, row, column, textValue, color)
label = uilabel(parent, ...
    'Text', textValue, ...
    'FontWeight', 'bold', ...
    'FontColor', color.Ink, ...
    'BackgroundColor', color.Soft, ...
    'HorizontalAlignment', 'center');
label.Layout.Row = row;
label.Layout.Column = column;
end

function label = makeBodyCell(parent, row, column, textValue, alignment, color)
label = uilabel(parent, ...
    'Text', textValue, ...
    'FontColor', color.Ink, ...
    'BackgroundColor', color.Surface, ...
    'HorizontalAlignment', alignment);
label.Layout.Row = row;
label.Layout.Column = column;
end

function setNavButton(button, isActive, color)
if isActive
    button.BackgroundColor = color.Blue;
    button.FontColor = [1, 1, 1];
else
    button.BackgroundColor = color.Surface;
    button.FontColor = color.Ink;
end
end

function styleAxes(axesHandle, titleValue, ylabelValue, color)
axesHandle.Color = color.Surface;
axesHandle.Box = 'on';
axesHandle.GridColor = color.Line;
axesHandle.XGrid = 'off';
axesHandle.YGrid = 'on';
axesHandle.XColor = color.Ink;
axesHandle.YColor = color.Ink;
axesHandle.FontSize = 10;
axesHandle.Title.String = titleValue;
axesHandle.Title.FontWeight = 'bold';
axesHandle.Title.Color = color.Ink;
axesHandle.YLabel.String = ylabelValue;
axesHandle.YLabel.Color = color.Ink;
axesHandle.XLabel.Color = color.Ink;
end

function emptyAxes(axesHandle, message, color)
axesHandle.XTick = [];
axesHandle.YTick = [];
text(axesHandle, 0.5, 0.5, message, ...
    'Units', 'normalized', ...
    'HorizontalAlignment', 'center', ...
    'VerticalAlignment', 'middle', ...
    'FontSize', 11, ...
    'Color', color.Muted);
end

function addBarLabels(axesHandle, values)
for index = 1:numel(values)
    if isfinite(values(index))
        text(axesHandle, index, values(index), ...
            sprintf(' %.5f', values(index)), ...
            'HorizontalAlignment', 'center', ...
            'VerticalAlignment', 'bottom', ...
            'FontWeight', 'bold');
    end
end
end

function value = passText(passed)
if passed
    value = 'PASS';
else
    value = 'FAIL';
end
end

function value = numberText(number, digits)
if isfinite(number)
    value = sprintf(['%.' num2str(digits) 'f'], number);
else
    value = '-';
end
end

function value = unitText(number, unit, digits)
if isfinite(number)
    value = sprintf(['%.' num2str(digits) 'f %s'], number, unit);
else
    value = '-';
end
end

function value = sentenceCase(textValue)
textValue = lower(char(textValue));
if isempty(textValue)
    value = '-';
else
    value = [upper(textValue(1)), textValue(2:end)];
end
end

function identifier = createScenarioID(prefix)
identifier = sprintf('%s_%s', prefix, ...
    char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
end

function closeProgress(progress)
if ~isempty(progress) && isvalid(progress)
    close(progress);
end
end
