function [ Sim, results ] = testAllForecasts( pars, allDemandValues, ...
    Sim, Pemd, Pfem, MPC, k)

% testAllForecasts: Test the performance of all trained (and non-trained)
% forecasts. First the parameterised forecasts are run to select the
% best parameters. Then these best selected ones are compared to other
% methods.

%% Pre-Allocation
% Index of the best forecasts for each instance (within Sim.lossTypes)
bestPfemIdx = zeros(Sim.nInstances, 1);
bestPemdIdx = zeros(Sim.nInstances, 1);

Sim.forecastSelectionIdxs = (1:(Sim.stepsPerHour*Sim.nHoursSelect)) + ...
    Sim.trainIdxs(end);
Sim.testIdxs = (1:(Sim.stepsPerHour*Sim.nHoursTest)) + ...
    Sim.forecastSelectionIdxs(end);

Sim.hourNumberSelection = Sim.hourNumber(Sim.forecastSelectionIdxs, :);
Sim.hourNumberTest = Sim.hourNumber(Sim.testIdxs, :);

peakReductions = cell(Sim.nInstances, 1);
peakPowers = cell(Sim.nInstances, 1);
smallestExitFlag = cell(Sim.nInstances, 1);
allKWhs = zeros(Sim.nInstances, 1);
lossTestResults = cell(Sim.nInstances, 1);

for instance = 1:Sim.nInstances
    peakReductions{instance} = zeros(Sim.nMethods,1);
    peakPowers{instance} = zeros(Sim.nMethods,1);
    smallestExitFlag{instance} = zeros(Sim.nMethods,1);
    lossTestResults{instance} = zeros(Sim.nMethods, Sim.nTrainMethods);
    allKWhs(instance) = mean(allDemandValues{instance});
end

%% Run Models for Forecast selection

% Extract data required from Sim structure for efficiency of parfor
% communications
batteryCapacityRatio = Sim.batteryCapacityRatio;
batteryChargingFactor = Sim.batteryChargingFactor;
trainIdxs = Sim.trainIdxs;
forecastSelectionIdxs = Sim.forecastSelectionIdxs;
testIdxs = Sim.testIdxs;
pfemRange = Pfem.range;
pemdRange = Pemd.range;
lossTypes = Sim.lossTypes;
allMethodStrings = Sim.allMethodStrings;

hourNumberSelection = Sim.hourNumberSelection;
stepsPerHour = Sim.stepsPerHour;
stepsPerDay = Sim.stepsPerDay;
nInstances = Sim.nInstances;

% Set any default values of MPC that aren't already set:
MPC = setDefaultValues(MPC, {'billingPeriodDays', 1, ...
    'maxParForTypes', 4});

forecastSelectionTic = tic;

allForecastsToSelectFrom = [pfemRange, pemdRange];
forecastOffset = 1;

nRuns = ceil(length(allForecastsToSelectFrom)/MPC.maxParForTypes);

disp('===== Forecast Selection =====')

for iRun = 1:nRuns
    
    theseForecasts = allForecastsToSelectFrom(forecastOffset:...
        min(forecastOffset + MPC.maxParForTypes - 1, end));
    
    forecastOffset = forecastOffset + MPC.maxParForTypes;
    
    poolobj = gcp('nocreate');
    delete(poolobj);
    
    parfor instance = 1:nInstances
        
        % Battery properties
        batteryCapacity = allKWhs(instance)*batteryCapacityRatio*...
            stepsPerDay;
        
        maximumChargeRate = batteryChargingFactor*batteryCapacity;
        
        % Separate Data into training and parameter selection sets
        demandValuesTrain = allDemandValues{instance}(trainIdxs, :);
        demandValuesSelection = allDemandValues{instance}(...
            forecastSelectionIdxs, :);
        
        peakLocalPower = max(demandValuesSelection);
        
        % Create 'historical load pattern' used for initialization etc.
        loadPattern = mean(reshape(demandValuesTrain, ...
            [k, length(demandValuesTrain)/k]), 2);
        
        godCastValues = zeros(length(testIdxs), k);
        for jj = 1:k
            godCastValues(:, jj) = ...
                circshift(demandValuesSelection, -[jj-1, 0]);
        end
        
        %% For each parametrized method run simulation
        for iForecastType = theseForecasts
            
            runControl = [];
            runControl.MPC = MPC;
            
            if strcmp(allMethodStrings{iForecastType},...
                    'setPoint'); %#ok<PFBNS>
                error(['Should not have found setPoint method during' ...
                    'parameter selection']);
            else
                runControl.MPC.setPoint = false;
            end
            
            runControl.naivePeriodic = false;
            runControl.godCast = false;
            runControl.skipRun = false;
            
            [runningPeak, exitFlag, forecastUsed] = mpcController( ...
                pars{instance, iForecastType}, godCastValues,...
                demandValuesSelection, batteryCapacity, ...
                maximumChargeRate, loadPattern, hourNumberSelection, ...
                stepsPerHour, k, runControl);
            
            %% Extract simulation results
            peakReductions{instance}(iForecastType) = ...
                extractSimulationResults(runningPeak',...
                demandValuesSelection, k*MPC.billingPeriodDays);
            
            peakPowers{instance}(iForecastType) = peakLocalPower;
            smallestExitFlag{instance}(iForecastType) = min(exitFlag);
            
            if strcmp(allMethodStrings{iForecastType}, 'forecastFree');
                error(['Should not have found forecastFree method ' ...
                    'during parameter selection']);
            end
            
            if strcmp(allMethodStrings{iForecastType}, 'setPoint');
                error(['Should not have found setPoint method ' ...
                    'during parameter selection']);
            end
            
            % Compute the performance of the forecast by all metrics
            for iMetric = 1:length(lossTypes)
                lossTestResults{instance}(iForecastType, iMetric)...
                    = mean(lossTypes{iMetric}(godCastValues',...
                    forecastUsed));
            end
        end
        
        disp(' ===== Completed instance: ===== ');
        disp(instance);
        
    end
    
    poolobj = gcp('nocreate');
    delete(poolobj);
    
    disp(' ===== Completed Forecast Types: ===== ');
    disp(theseForecasts);
    
end

timeSelection = toc(forecastSelectionTic);
disp('Time to Select Forecast Parameters:'); disp(timeSelection);

% Find the best forecast metrics from the parameter grid search
for instance = 1:nInstances
    if ~isempty(pfemRange)
        [~, idx] = max(peakReductions{instance}(pfemRange));
        bestPfemIdx(instance) = idx + min(pfemRange) - 1;
    end
    
    if ~isempty(pemdRange)
        [~, idx] = max(peakReductions{instance}(pemdRange));
        bestPemdIdx(instance) = idx + min(pemdRange) - 1;
    end
end

%% Extend relevant variables to accomodate the 2 'new' forecasts
% If they exist:

if Pfem.num > 0
    Sim.allMethodStrings = [allMethodStrings, {'bestPfemSelected'}];
end
if Pemd.num > 0
    Sim.allMethodStrings = [Sim.allMethodStrings, {'bestPemdSelected'}];
end
    
Sim.nMethods = length(Sim.allMethodStrings);

for instance = 1:nInstances
    peakReductions{instance} = zeros(Sim.nMethods,1);
    peakPowers{instance} = zeros(Sim.nMethods,1);
    smallestExitFlag{instance} = zeros(Sim.nMethods,1);
    lossTestResults{instance} = zeros(Sim.nMethods, Sim.nTrainMethods);
end

%% Run Models for Performance Testing

% Extract data from Sim struct for efficiency in parfor communication
nMethods = Sim.nMethods;
nTrainMethods = Sim.nTrainMethods;
allMethodStrings = Sim.allMethodStrings;
hourNumberTest = Sim.hourNumberTest;
stepsPerHour = Sim.stepsPerHour;

testingTic = tic;

poolobj = gcp('nocreate');
delete(poolobj);

disp('===== Forecast Testing =====')

% for instance = 1:nInstances
parfor instance = 1:nInstances
    
    %% Battery properties
    batteryCapacity = allKWhs(instance)*batteryCapacityRatio*stepsPerDay;
    maximumChargeRate = batteryChargingFactor*batteryCapacity;
    
    % Separate data for parameter selection and testing
    demandValuesSelection = allDemandValues{instance}(...
        forecastSelectionIdxs);
    demandValuesTest = allDemandValues{instance}(testIdxs);
    peakLocalPower = max(demandValuesTest);
    
    % Create 'historical load pattern' used for initialization etc.
    loadPattern = mean(reshape(demandValuesSelection, ...
        [k, length(demandValuesSelection)/k]), 2);
    
    % Create godCast forecasts
    godCastValues = zeros(length(testIdxs), k);
    for jj = 1:k
        godCastValues(:, jj) = circshift(demandValuesTest, -[jj-1, 0]);
    end
    
    % Avoid parfor errors
    forecastUsed = []; exitFlag = [];
    
    %% Test performance of all methods
    
    for methodType = 1:nMethods
        
        runControl = [];
        runControl.MPC = MPC;
        thisMethodString = allMethodStrings{methodType}; %#ok<PFBNS>
        
        if strcmp(thisMethodString, 'forecastFree')
            
            %% Forecast Free Controller
            demandValuesTrain = allDemandValues{instance}(trainIdxs, :);
            
            % Create 'historical load pattern' used for initialization etc.
            loadPatternTrain = mean(reshape(demandValuesTrain, ...
                [k, length(demandValuesTrain)/k]), 2);
            
            % Evaluate performance of controller
            [ runningPeak ] = mpcControllerForecastFree( ...
                pars{instance, methodType}, demandValuesTest,...
                batteryCapacity, maximumChargeRate, loadPatternTrain,...
                hourNumberTest, stepsPerHour, MPC);
            
            runControl.skipRun = false;
        else
            
            %% Normal forecast-driven or set-point controller
           
            % If we are using 'bestSelected' forecast then set forecast
            % index
            if strcmp(thisMethodString, 'bestPfemSelected')
                iForecastType = bestPfemIdx(instance);
                
            elseif strcmp(thisMethodString, 'bestPemdSelected')
                iForecastType = bestPemdIdx(instance);
                
            else
                iForecastType = methodType;
            end
            
            % Check for godCast or naivePeriodic
            runControl.naivePeriodic = strcmp(thisMethodString,...
                'naivePeriodic');
            
            runControl.godCast = strcmp(thisMethodString, 'godCast');
            
            runControl.MPC.setPoint = strcmp(thisMethodString, 'setPoint');
            
            % If method is set-point then show it current demand
            if(runControl.MPC.setPoint)
                runControl.MPC.knowCurrentDemandNow = true;
            end
            
            % Check if forecast is in the set of {Pfem, Pemd} forecasts
            % in which case produce forecast but don't run simulation
            if ismember(methodType, [pfemRange, pemdRange])
                runControl.skipRun = true;
            else
                runControl.skipRun = false;
            end
            
            [runningPeak, exitFlag, forecastUsed] = mpcController( ...
                pars{instance, iForecastType}, godCastValues,...
                demandValuesTest, batteryCapacity, maximumChargeRate, ...
                loadPattern, hourNumberTest, stepsPerHour, k,...
                runControl); %#ok<PFBNS>
        end
        
        if ~runControl.skipRun
            
            % ====== DEBUGGING ====== :
            % plot([runningPeak', demandValuesTest]);
            % legend('Running Peak [kW]', 'Local Demand [kWh]');
            % ====== ======
            
            % Extract simulation results
            peakReductions{instance}(methodType) = ...
                extractSimulationResults(runningPeak',...
                demandValuesTest, k*MPC.billingPeriodDays);
            
            peakPowers{instance}(methodType) = peakLocalPower;
            smallestExitFlag{instance}(methodType) = min(exitFlag);
        end
        
        % Compute the performance of the forecast by all metrics
        isForecastFree = strcmp(thisMethodString, 'forecastFree');
        isSetPoint = strcmp(thisMethodString, 'setPoint');
        
        if (~isForecastFree && ~isSetPoint)
            for iMetric = 1:length(lossTypes)
                lossTestResults{instance}(methodType, iMetric)...
                    = mean(lossTypes{iMetric}(godCastValues', ...
                    forecastUsed));
            end
        end
    end
    
    disp(' ===== Completed Instance: ===== ');
    disp(instance);
    
end

poolobj = gcp('nocreate');
delete(poolobj);

timeTesting = toc(testingTic);
disp('Time for Testing Forecasts:'); disp(timeTesting);


%% Convert to arrays from cellArrays
% Use for loops to avoid the confusion of reshape statements

peakPowersArray = zeros(nMethods, Sim.nAggregates, length(Sim.nCustomers));
peakReductionsArray = peakPowersArray;
smallestExitFlagArray = peakPowersArray;
allKWhsArray = zeros(Sim.nAggregates, length(Sim.nCustomers));
lossTestResultsArray = zeros([nMethods, Sim.nAggregates, ...
    length(Sim.nCustomers), nTrainMethods]);

instance = 0;
for nCustomerIdx = 1:length(Sim.nCustomers)
    for trial = 1:Sim.nAggregates
        
        instance = instance + 1;
        allKWhsArray(trial, nCustomerIdx) = allKWhs(instance, 1);
        
        for iMethod = 1:nMethods
            
            peakPowersArray(iMethod, trial, nCustomerIdx) = ...
                peakPowers{instance}(iMethod, 1);
            
            peakReductionsArray(iMethod, trial, nCustomerIdx) = ...
                peakReductions{instance}(iMethod, 1);
            
            smallestExitFlagArray(iMethod, trial, nCustomerIdx) = ...
                smallestExitFlag{instance}(iMethod, 1);
            
            for metric = 1:nTrainMethods
                
                lossTestResultsArray(iMethod, trial, nCustomerIdx, ...
                    metric) = lossTestResults{instance}(iMethod, metric);
                
            end
        end
    end
end

%% Fromatting
% Collapse Trial Dimension
peakReductionsTrialFlattened = reshape(peakReductionsArray, ...
    [nMethods, length(Sim.nCustomers)*Sim.nAggregates]);

peakPowersTrialFlattened = reshape(peakPowersArray, ...
    [nMethods, length(Sim.nCustomers)*Sim.nAggregates]);

%% Put results together in structure for passing out
results.peakReductions = peakReductionsArray;
results.peakReductionsTrialFlattened = peakReductionsTrialFlattened;
results.peakPowers = peakPowersArray;
results.peakPowersTrialFlattened = peakPowersTrialFlattened;
results.smallestExitFlag = smallestExitFlagArray;
results.allKWhs = allKWhsArray;
results.lossTestResults = lossTestResultsArray;
results.bestPfemForecast = bestPfemIdx;
results.bestPemdForecast = bestPemdIdx;

end
