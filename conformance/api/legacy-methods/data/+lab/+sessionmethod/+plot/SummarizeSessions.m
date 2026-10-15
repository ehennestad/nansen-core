classdef SummarizeSessions < nansen.session.SessionMethod
%SUMMARIZESESSIONS Write a line about each session, all of them at once.

    properties (Constant) % SessionMethod attributes
        MethodName = 'Summarize sessions'
        BatchMode = 'batch'
        IsManual = false
        IsQueueable = false;
        OptionsManager = nansen.OptionsManager(mfilename('class'))
    end

    properties (Constant)
        DATA_SUBFOLDER = 'summary'
        VARIABLE_PREFIX = ''
    end

    methods
        function obj = SummarizeSessions(varargin)
            obj@nansen.session.SessionMethod(varargin{:})
            if ~nargout
                obj.runMethod()
                clear obj
            end
        end
    end

    methods (Static)
        function options = getDefaultOptions()
            options = struct();
            options.Prefix = 'Session'; % Put before each line
            options.Repeat = 2;
            options.Mode = 'short';
            options.Mode_ = {'short', 'long'};
        end
    end

    methods
        function runMethod(obj)
            for i = 1:numel(obj.SessionObjects)
                session = obj.SessionObjects(i);
                line = sprintf('%s %s of %s', obj.Options.Prefix, session.sessionID, session.subjectID);
                session.saveData('SessionSummary', strjoin(repmat({line}, 1, obj.Options.Repeat), newline), ...
                    'FileType', '.txt')
            end
        end
    end
end
