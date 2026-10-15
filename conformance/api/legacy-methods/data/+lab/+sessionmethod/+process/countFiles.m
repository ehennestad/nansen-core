function varargout = countFiles(sessionObject, varargin)
%COUNTFILES Count the files of a session's folder and save the count.
%
%   A session method as NANSEN dev's template writes one.

% % % % % % % % % % % % CONFIGURATION CODE BLOCK % % % % % % % % % % % %
    % Get struct of parameters from local function
    params = getDefaultParameters();

    % Create a cell array with attribute keywords
    ATTRIBUTES = {'serial', 'queueable'};

% % % % % % % % % % % % % DEFAULT CODE BLOCK % % % % % % % % % % % % % %
    import nansen.session.SessionMethod
    fcnAttributes = SessionMethod.setAttributes(params, ATTRIBUTES{:});

    if ~nargin && nargout > 0
        varargout = {fcnAttributes};   return
    end

    params = utility.parsenvpairs(params, [], varargin);

% % % % % % % % % % % % % % CUSTOM CODE BLOCK % % % % % % % % % % % % % %
    folder = sessionObject.getSessionFolder(params.DataLocation);
    listing = dir(fullfile(folder, ['*', params.Extension]));
    result = struct('sessionID', sessionObject.sessionID, 'count', numel(listing) * params.Scale, ...
        'label', char(params.Label), 'window', params.Window, 'verbose', params.Advanced.Verbose);
    sessionObject.saveData('FileCount', result)
    if nargout; varargout = {sessionObject}; end
end

function params = getDefaultParameters()
%getDefaultParameters Get the default parameters for this session method
    params = struct();
    params.DataLocation = 'Raw'; % The data location whose files are counted
    params.Extension = '.tif';   % Which files are counted
    params.Extension_ = {'.tif', '.txt'};
    params.Scale = 1;
    params.Label = "it's 100% files";
    params.Window = [1, 10];
    params.Tags = {'a', 'b'};
    params.Advanced.Verbose = false; % Print what is counted
    params.Unknown = [];
    params.Computed = getenv('HOME');
end
