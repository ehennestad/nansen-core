classdef OptionsManager < handle
%OptionsManager What dev's session methods use of dev's OptionsManager: the default options of a function or class
%
%   dev's session method classes keep one as a constant property
%   (OptionsManager = nansen.OptionsManager(mfilename('class'))). Options
%   and getOptions give the class's getDefaultOptions, or a function's
%   DefaultOptions attribute; presets are the project's here, so there are
%   none to choose from.

    properties (SetAccess = private)
        FunctionName (1,1) string = ""
    end

    properties (Dependent)
        Options
    end

    methods
        function obj = OptionsManager(functionName, varargin)
            if nargin > 0
                obj.FunctionName = string(functionName);
            end
        end

        function options = get.Options(obj)
            options = obj.getOptions();
        end

        function options = getOptions(obj, varargin)
            options = struct();
            if obj.FunctionName == ""
                return
            end
            try
                if ~isempty(meta.class.fromName(obj.FunctionName))
                    options = feval(obj.FunctionName + ".getDefaultOptions");
                else
                    attributes = feval(obj.FunctionName);
                    options = attributes.DefaultOptions;
                end
            catch
                options = struct();
            end
        end
    end
end
