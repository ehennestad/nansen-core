classdef MethodContext < handle
%MethodContext What a running method gets besides its entity and options
%
%   The project, a log, progress and cancellation. OnLog(line) and
%   OnProgress(fraction, message) are called when set; nothing is global.

    properties
        Project = []
        Method = []
        OnLog = []
        OnProgress = []
    end

    properties (SetAccess = private)
        Lines (1,:) string = string.empty(1, 0)
        Fraction (1,1) double = 0
        Cancelled (1,1) logical = false
    end

    methods
        function obj = MethodContext(options)
            arguments
                options.Project = []
                options.Method = []
                options.OnLog = []
                options.OnProgress = []
            end
            obj.Project = options.Project;
            obj.Method = options.Method;
            obj.OnLog = options.OnLog;
            obj.OnProgress = options.OnProgress;
        end

        function log(obj, message, varargin)
            if ~isempty(varargin)
                message = sprintf(message, varargin{:});
            end
            line = string(datetime("now", Format="HH:mm:ss")) + " " + string(message);
            obj.Lines(end + 1) = line;
            if ~isempty(obj.OnLog)
                obj.OnLog(line);
            end
        end

        function progress(obj, fraction, message)
            arguments
                obj
                fraction (1,1) double
                message (1,1) string = ""
            end
            obj.Fraction = max(0, min(1, fraction));
            if ~isempty(obj.OnProgress)
                obj.OnProgress(obj.Fraction, message);
            end
        end

        function cancel(obj)
            obj.Cancelled = true;
        end

        function checkCancelled(obj)
            %checkCancelled Throw nansen:Cancelled when the run was cancelled
            if obj.Cancelled
                error("nansen:Cancelled", "The run was cancelled")
            end
        end
    end
end
