classdef ViewableProject < handle
%ViewableProject A project as a method run on a viewable sees it (view.run)
%
%   The variable named by its stack option is the viewable's stack, and the
%   one its rois option names, when it has one, the viewable's ROIs; what
%   it saves (save, a stack writer) is written beside the stack's file as
%   <stem>_<name>.npy (an array of numbers or truth values, more than one)
%   or <stem>_<name>.json (anything else), and read back from there; for an
%   array, it is kept in memory. Nothing else is there to read
%   (data-not-found). No progress is kept: a run that stops starts over.
%   As Python's nansen.viewables.ViewableProject.

    properties (SetAccess = private)
        Names (1, :) string = string.empty(1, 0)   % what was saved, in order
        Paths (1, :) string = string.empty(1, 0)   % each one's file, or "" when it is kept in memory
        Values (1, :) cell = {}                    % each one's value, or [] when it is in its file
        InFile (1, :) logical = logical.empty(1, 0)
        StackFrameLimit (1, 1) double = Inf
    end

    properties (Access = private)
        Viewables   % the nansen.Viewables
        Item        % the viewable's struct
        StackName (1, 1) string
        RoisName (1, 1) string
        Scratch (1, 1) string = ""
    end

    properties (Dependent)
        Folder
    end

    methods
        function obj = ViewableProject(viewables, item, stackName, roisName)
            obj.Viewables = viewables;
            obj.Item = item;
            obj.StackName = stackName;
            obj.RoisName = roisName;
            if item.path == ""
                obj.Scratch = string(tempname);
            end
        end

        function value = get.Folder(obj)
            % Where relative paths a method is given lead: the stack's folder; a folder of its own for an array
            if obj.Item.path ~= ""
                value = string(fileparts(obj.Item.path));
                return
            end
            if ~isfolder(obj.Scratch)
                mkdir(obj.Scratch);
            end
            value = obj.Scratch;
        end

        function registry = adapters(obj)
            registry = obj.Viewables.adapters();
        end

        function stack = openStack(obj, ~, name, frames)
            at = find(obj.Names == string(name), 1);
            if ~isempty(at)
                if obj.InFile(at)
                    stack = nansen.adapters.Npy().open(obj.Paths(at));
                else
                    stack = nansen.Stack.fromArray(obj.Values{at});
                end
            elseif string(name) == obj.StackName
                stack = obj.Viewables.stack(obj.Item);
            else
                nansen.internal.throwError("data-not-found", "%s has no '%s': a method run on it reads its stack, as '%s'", ...
                    obj.Item.name, name, obj.StackName)
            end
            if nargin >= 4 && ~isempty(frames)
                stack = stack.cut(frames(1), frames(2));
            end
        end

        function data = load(obj, entity, name, varargin)
            at = find(obj.Names == string(name), 1);
            if ~isempty(at)
                if ~obj.InFile(at)
                    data = obj.Values{at};
                elseif endsWith(obj.Paths(at), ".npy")
                    data = nansen.adapters.Npy().read(obj.Paths(at));
                else
                    data = nansen.adapters.Json().read(obj.Paths(at));
                end
                return
            end
            if string(name) == obj.RoisName && string(name) ~= obj.StackName
                if ~obj.Item.hasRois
                    nansen.internal.throwError("data-not-found", "%s has no ROIs yet: draw them, or find them first", obj.Item.name)
                end
                data = obj.Item.rois;
                return
            end
            stack = obj.openStack(entity, name);
            data = stack.all();
        end

        function path = save(obj, entity, name, data)
            isArray = (isnumeric(data) || islogical(data)) && numel(data) > 1;
            path = obj.outputPath(name, isArray);
            if path == ""
                obj.keep(name, "", data, false);
                path = obj.writePath(entity, name);
                return
            end
            if isArray
                nansen.adapters.Npy().write(path, data);
                obj.keep(name, path, [], true);
            else
                nansen.adapters.Json().write(path, data);
                obj.keep(name, path, data, false);
            end
        end

        function writer = stackWriter(obj, ~, name, dimensions, className)
            if strlength(string(name)) == 0
                writer = nansen.StackWriter(dimensions, className);
                return
            end
            path = obj.outputPath(name, true);
            if path == ""
                obj.keep(name, "", [], false);
                writer = nansen.StackWriter(dimensions, className, Finish=@(data) obj.keep(name, "", data, false));
                return
            end
            obj.keep(name, path, [], true);
            writer = nansen.adapters.Npy().create(path, dimensions, className);
        end

        function progress = checkpoint(obj, entity, name, dimensions, className, options, source, settings) %#ok<INUSD>
            %checkpoint No progress is kept: the run starts from the first frame
            arguments
                obj
                entity
                name
                dimensions (1, :) double
                className (1, 1) string
                options
                source
                settings.Passes (1, 1) double = 1
                settings.Method = []
            end
            progress = nansen.Checkpoint("", string(name), dimensions, className, struct(), Passes=settings.Passes, ...
                Create=@() obj.stackWriter(entity, name, dimensions, className));
        end

        function names = updateValues(~, ~, ~)
            %updateValues There is no table: no column is written
            names = strings(1, 0);
        end

        function path = writePath(obj, ~, name)
            %writePath Where a method that writes files itself (an external tool) writes: <stem>_<name> beside the stack
            stem = obj.Item.name;
            if obj.Item.path ~= ""
                [~, stem] = fileparts(obj.Item.path);
            end
            path = string(fullfile(obj.Folder, stem + "_" + string(name)));
        end
    end

    methods (Access = private)
        function path = outputPath(obj, name, isArray)
            % <stem>_<name>.npy or .json beside the stack's file; "" for an array, whose outputs are kept in memory
            path = "";
            if obj.Item.path == ""
                return
            end
            [folder, stem] = fileparts(obj.Item.path);
            extension = ".json";
            if isArray
                extension = ".npy";
            end
            path = string(fullfile(folder, stem + "_" + string(name) + extension));
        end

        function keep(obj, name, path, value, inFile)
            at = find(obj.Names == string(name), 1);
            if isempty(at)
                at = numel(obj.Names) + 1;
                obj.Names(at) = string(name);
            end
            obj.Paths(at) = string(path);
            obj.Values{at} = value;
            obj.InFile(at) = inFile;
        end
    end
end
