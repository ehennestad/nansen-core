classdef SessionMethod < handle
%SessionMethod NANSEN dev's base class of session methods, for those imported into nansen-core
%
%   The parts of dev's nansen.session.SessionMethod (and of its bases
%   nansen.processing.DataMethod and nansen.mixin.HasOptions) that dev's
%   session methods use: SessionObjects, Options (dev's defaults, from the
%   class's static getDefaultOptions, with the options given over them),
%   loadData, saveData, getDataFilePath, getTargetFolder and existVariable
%   (of the session), run (runMethod, or main), and setAttributes, which
%   function methods call. The sessions are nansen.legacy.SessionShim
%   objects; nansen.legacy.runSessionMethod constructs a method with them
%   and calls run. It is on the path only while such methods run
%   (nansen.legacy.addCompatibility).

    properties
        SessionObjects          % the nansen.legacy.SessionShim objects it runs on
        Options = struct()      % dev's default options with those it was given over them
        RedoIfCompleted = false
    end

    properties (Access = protected)
        DataIoModel             % the sessions, as dev's DataMethod keeps them
        Parameters
    end

    methods
        function obj = SessionMethod(varargin)
            % obj = SessionMethod(sessions, options) or SessionMethod(sessions, Name, Value, ...); none for an
            % object that runs later
            if isempty(varargin)
                return
            end
            if ~isa(varargin{1}, 'nansen.legacy.SessionShim')
                error("Nansen:SessionMethod:InvalidSession", ...
                    "First input must be a valid session object or a list of valid session objects")
            end
            obj.SessionObjects = varargin{1};
            obj.DataIoModel = varargin{1};
            obj.Options = utility.parsenvpairs(nansen.session.SessionMethod.defaultsOf(class(obj)), 1, varargin(2:end));
            obj.Parameters = obj.Options;
            obj.checkRequiredVariables()
        end

        function run(obj)
            %run dev's SessionMethod.run: the method's runMethod, or its main
            if ismethod(obj, 'runMethod')
                obj.runMethod();
            elseif ismethod(obj, 'main')
                obj.main();
            else
                error("Nansen:SessionMethod:NoRunMethod", "%s has neither a runMethod nor a main method", class(obj))
            end
        end

        function checkRequiredVariables(obj)
            % dev's check, for a method with RequiredVariables, that their files are there
            if ~isprop(obj, 'RequiredVariables')
                return
            end
            names = string(obj.RequiredVariables);
            for name = reshape(names, 1, [])
                if ~isfile(obj.getDataFilePath(name))
                    error("Nansen:SessionMethod:RequiredDataMissing", "File for the required data variable ""%s"" is missing", name)
                end
            end
        end

        function data = loadData(obj, varargin)
            data = obj.DataIoModel.loadData(varargin{:});
        end

        function saveData(obj, varargin)
            obj.DataIoModel.saveData(varargin{:})
        end

        function varargout = getDataFilePath(obj, varargin)
            varargout = cell(1, max(1, nargout));
            [varargout{:}] = obj.DataIoModel.getDataFilePath(varargin{:});
        end

        function folder = getTargetFolder(obj)
            folder = obj.DataIoModel.getSessionFolder();
        end

        function tf = existVariable(obj, varName)
            tf = isfile(obj.getDataFilePath(varName));
        end
    end

    methods (Static)
        function options = getDefaultOptions()
            %getDefaultOptions A session method class's default options; classes with options define their own
            options = struct();
        end

        function options = defaultsOf(className)
            % The default options of a session method class: its static getDefaultOptions
            options = struct();
            try
                options = feval(string(className) + ".getDefaultOptions");
            catch
            end
            if ~(isstruct(options) && isscalar(options))
                options = struct();
            end
        end

        function attributes = setAttributes(varargin)
            %setAttributes dev's attributes of a function session method
            %
            %   S = setAttributes(params, flags..., Name, Value...) gives BatchMode
            %   ('serial', or 'batch' with the flag batch), IsQueueable (false with
            %   unqueueable), Alternatives, MethodName (the calling function's name
            %   as words) and DefaultOptions (params), as dev's.
            attributes = struct("BatchMode", 'serial', "IsQueueable", true, "Alternatives", {{}}, "MethodName", '');
            defaults = struct();
            if ~isempty(varargin) && isstruct(varargin{1})
                defaults = varargin{1};
                varargin = varargin(2:end);
            end
            attributes.DefaultOptions = defaults;
            flags = strings(1, 0);
            k = 1;
            while k <= numel(varargin)
                item = varargin{k};
                isText = (ischar(item) || (isstring(item) && isscalar(item)));
                if isText && ismember(lower(string(item)), ["batch", "serial", "queueable", "unqueueable"])
                    flags(end + 1) = lower(string(item)); %#ok<AGROW>
                    k = k + 1;
                elseif isText && k < numel(varargin) && isfield(attributes, char(item))
                    attributes.(char(item)) = varargin{k + 1};
                    k = k + 2;
                else
                    k = k + 1;
                end
            end
            if ismember("batch", flags)
                attributes.BatchMode = 'batch';
            end
            if ismember("unqueueable", flags)
                attributes.IsQueueable = false;
            end
            if isempty(attributes.MethodName)
                stack = dbstack(1);
                if ~isempty(stack)
                    name = regexprep(stack(1).name, '^.*[.>]', '');
                    name = strtrim(regexprep(regexprep(name, '([a-z0-9])([A-Z])', '$1 $2'), '_', ' '));
                    if ~isempty(name)
                        name(1) = upper(name(1));
                    end
                    attributes.MethodName = name;
                end
            end
        end
    end
end
