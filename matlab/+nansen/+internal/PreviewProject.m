classdef PreviewProject < handle
%PreviewProject A project as a method sees it in a preview (methods.preview)
%
%   Stacks it opens (or loads, for image stacks) are cut to their first
%   Frames frames, and what it saves or writes as a stack is kept in
%   memory, where it reads it back from; nothing is written to the project.
%   A method that writes files itself (an external tool) writes to a folder
%   deleted after the preview. As Python's nansen.preview.PreviewProject.

    properties (SetAccess = private)
        Inner        % the nansen.Project
        Frames (1, 1) double
        Names (1, :) string = string.empty(1, 0)   % what was saved, in order
        Values (1, :) cell = {}
    end

    properties (Access = private)
        Scratch (1, 1) string = ""
    end

    properties (Dependent)
        Folder
        StackFrameLimit
    end

    methods
        function obj = PreviewProject(project, frames)
            obj.Inner = project;
            obj.Frames = double(frames);
        end

        function value = get.Folder(obj)
            value = obj.Inner.Folder;
        end

        function value = get.StackFrameLimit(obj)
            value = obj.Inner.StackFrameLimit;
        end

        function value = dataset(obj, varargin)
            value = obj.Inner.dataset(varargin{:});
        end

        function value = dataVariable(obj, name)
            value = obj.Inner.dataVariable(name);
        end

        function stack = openStack(obj, entity, name)
            at = find(obj.Names == string(name), 1);
            if ~isempty(at)
                stack = nansen.Stack.fromArray(obj.Values{at});
            else
                whole = obj.Inner.openStack(entity, name);
                count = min(obj.Frames, whole.Size(end));
                if numel(whole.Size) < 3 || count == whole.Size(end)
                    stack = whole;
                else
                    stack = nansen.Stack([whole.Size(1:end - 1), count], whole.ClassName, @(first, last) whole.frames(first, min(last, count)));
                    stack.Metadata = whole.Metadata;
                end
            end
            stack.MaxFrames = obj.Inner.StackFrameLimit;
        end

        function data = load(obj, entity, name, varargin)
            at = find(obj.Names == string(name), 1);
            if ~isempty(at)
                data = obj.Values{at};
                return
            end
            data = obj.Inner.load(entity, name, varargin{:});
            variable = obj.Inner.dataVariable(name);
            if string(nansen.internal.getField(variable.Document, "dataType", "")) == "ImageStack" && isnumeric(data) && ndims(data) >= 3
                index = repmat({':'}, 1, ndims(data));
                index{end} = 1:min(obj.Frames, size(data, ndims(data)));
                data = data(index{:});
            end
        end

        function path = save(obj, entity, name, data)
            obj.keep(name, data);
            path = obj.writePath(entity, name);
        end

        function writer = stackWriter(obj, ~, name, dimensions, className)
            if strlength(string(name)) == 0
                writer = nansen.StackWriter(dimensions, className);
            else
                writer = nansen.StackWriter(dimensions, className, Finish=@(data) obj.keep(name, data));
            end
        end

        function progress = checkpoint(obj, entity, name, dimensions, className, options, source, settings) %#ok<INUSD>
            %checkpoint No progress is kept: a preview starts from the first frame, and its stacks are kept in memory
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

        function names = updateValues(obj, entity, values)
            %updateValues The columns the values would be written to; nothing is written
            names = nansen.Project.writableNames(obj.Inner.table(entity.EntityType), values);
        end

        function path = writePath(obj, entity, name)
            if obj.Scratch == ""
                obj.Scratch = string(tempname);
            end
            [~, file, extension] = fileparts(obj.Inner.writePath(entity, name));
            path = fullfile(obj.Scratch, strjoin(string(struct2cell(entity.Key))', "_"), file + extension);
        end

        function close(obj)
            if obj.Scratch ~= "" && isfolder(obj.Scratch)
                rmdir(obj.Scratch, "s");
            end
        end

        function delete(obj)
            obj.close();
        end
    end

    methods (Access = private)
        function keep(obj, name, data)
            at = find(obj.Names == string(name), 1);
            if isempty(at)
                obj.Names(end + 1) = string(name);
                obj.Values{end + 1} = data;
            else
                obj.Values{at} = data;
            end
        end
    end
end
