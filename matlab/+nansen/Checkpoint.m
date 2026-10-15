classdef Checkpoint < handle
%Checkpoint The progress of a stack output while it is written, so a run that stopped goes on where it stopped
%
%   As dev's ImageStackProcessor (checkIfPartIsFinished): a method that
%   writes a stack a chunk of frames at a time asks the project for one
%   (Project.checkpoint). After each chunk it saves how many frames are
%   done, with what it needs to go on from there (its state: arrays, kept
%   exactly as the base64 of their bytes), in <output file>.progress.json
%   beside the output file: a nansen.progress document. It also holds the
%   inputs the run started from (the options, the input stack's size and
%   type, the method's version). Run again with the same inputs, the method
%   goes on from the first frame not done, writing into the output file it
%   had begun (an adapter with reopen: npy, ophys.binary_stack), and the
%   result is the one a run that never stopped gives. With other inputs, or
%   an output that cannot be reopened, it starts over. The file is removed
%   once the output is complete.
%
%   A method that goes through the frames more than once (motion
%   correction's iterations) writes its output in the last pass. PassNumber
%   (from 1) and FramesDone are where it goes on from, with State (a struct
%   of arrays) as it was saved there; a run from the beginning has pass 1,
%   no frames done and no state. writer() gives the output's writer: the
%   reopened file when the run goes on in the pass that writes it, else a
%   new one. save after each chunk, finish once the output is complete.
%   Python's nansen.progress.Checkpoint is the same, and reads and writes
%   the same files.

    properties (SetAccess = private)
        Path (1, 1) string = ""         % the progress document; "" when nothing is kept
        OutputPath (1, 1) string = ""
        Variable (1, 1) string = ""
        Size (1, :) double
        ClassName (1, 1) string
        Inputs                          % as JSON gives them back
        Passes (1, 1) double = 1
        MethodRef = []                  % struct id, version, as JSON gives it back; [] for any
        PassNumber (1, 1) double = 1
        FramesDone (1, 1) double = 0
        State (1, 1) struct = struct()
        Resumed (1, 1) logical = false
    end

    properties (Access = private)
        Create = []
        Reopen = []
        OutputWriter = []
    end

    methods
        function obj = Checkpoint(outputPath, variable, dimensions, className, inputs, options)
            arguments
                outputPath (1, 1) string
                variable (1, 1) string
                dimensions (1, :) double
                className (1, 1) string
                inputs
                options.Passes (1, 1) double = 1
                options.Method = []
                options.Create = []
                options.Reopen = []
            end
            obj.OutputPath = outputPath;
            if outputPath ~= ""
                obj.Path = nansen.Checkpoint.progressPath(outputPath);
            end
            obj.Variable = variable;
            obj.Size = dimensions;
            obj.ClassName = className;
            obj.Inputs = jsondecode(jsonencode(inputs));
            obj.Passes = options.Passes;
            if ~isempty(options.Method)
                obj.MethodRef = jsondecode(jsonencode(options.Method));
            end
            obj.Create = options.Create;
            obj.Reopen = options.Reopen;
            obj.readProgress();
        end

        function frame = firstFrame(obj, passNumber)
            %firstFrame Where the pass starts (from 1): after the frames done when the run goes on in it, else at 1
            frame = 1;
            if passNumber == obj.PassNumber
                frame = obj.FramesDone + 1;
            end
        end

        function out = writer(obj)
            %writer The output's writer: the one reopened to go on with, or a new one (which starts the file afresh)
            if isempty(obj.OutputWriter)
                if isempty(obj.Create)
                    obj.OutputWriter = nansen.StackWriter(obj.Size, obj.ClassName);
                else
                    obj.OutputWriter = obj.Create();
                end
            end
            out = obj.OutputWriter;
        end

        function save(obj, passNumber, framesDone, state)
            %save That the first framesDone frames of the pass are done (and written, in the pass that writes the
            %output), and what the method needs to go on from there: a struct of arrays. In the last pass of an
            %output that cannot be reopened, nothing is saved: that pass starts over.
            arguments
                obj
                passNumber (1, 1) double
                framesDone (1, 1) double
                state (1, 1) struct = struct()
            end
            if obj.Path == "" || (passNumber == obj.Passes && isempty(obj.Reopen))
                return
            end
            entry = nansen.internal.schemaEntry("nansen.progress");
            document = struct("schemaType", 'nansen.progress', "schemaVersion", char(entry.version));
            if ~isempty(obj.MethodRef)
                document.method = obj.MethodRef;
            end
            document.output = struct("variable", char(obj.Variable), "shape", obj.Size, ...
                "dtype", char(nansen.Checkpoint.typeName(obj.ClassName)));
            document.inputs = obj.Inputs;
            document.pass = passNumber;
            document.passes = obj.Passes;
            document.framesDone = framesDone;
            encoded = struct();
            names = fieldnames(state);
            for i = 1:numel(names)
                encoded.(names{i}) = nansen.Checkpoint.encode(state.(names{i}));
            end
            document.state = encoded;
            document.updatedAt = char(datetime("now", Format="yyyy-MM-dd'T'HH:mm:ss"));
            nansen.checkDocument(document, ExpectedType="nansen.progress");
            folder = fileparts(obj.Path);
            if ~isfolder(folder)
                mkdir(folder);
            end
            [~, suffix] = fileparts(tempname);
            temporary = obj.Path + "." + string(suffix) + ".tmp";
            nansen.internal.writeJson(temporary, document)
            movefile(temporary, obj.Path, "f");
        end

        function finish(obj)
            %finish The output is complete (or is started afresh): the progress document goes
            if obj.Path ~= "" && isfile(obj.Path)
                delete(obj.Path);
            end
        end
    end

    methods (Access = private)
        function readProgress(obj)
            if obj.Path == "" || ~isfile(obj.Path)
                return
            end
            try
                document = nansen.readDocument(obj.Path, ExpectedType="nansen.progress");
                state = struct();
                if isfield(document, "state") && isstruct(document.state)
                    names = fieldnames(document.state);
                    for i = 1:numel(names)
                        state.(names{i}) = nansen.Checkpoint.decode(document.state.(names{i}));
                    end
                end
            catch
                document = [];   % unreadable
            end
            if isempty(document) || ~obj.matches(document)
                obj.finish();   % another run's, or unreadable: start over
                return
            end
            passNumber = double(document.pass);
            done = double(document.framesDone);
            writer = [];
            if passNumber == obj.Passes && done > 0   % the output was being written: go on writing it
                writer = obj.reopened(done);
                if isempty(writer)
                    obj.finish();   % it cannot be: start over
                    return
                end
            end
            obj.PassNumber = passNumber;
            obj.FramesDone = done;
            obj.State = state;
            obj.Resumed = true;
            obj.OutputWriter = writer;
        end

        function tf = matches(obj, document)
            output = document.output;
            tf = isequal(double(output.shape(:)'), obj.Size) && string(output.dtype) == nansen.Checkpoint.typeName(obj.ClassName) ...
                && double(document.passes) == obj.Passes && document.pass >= 1 && document.pass <= obj.Passes ...
                && document.framesDone >= 0 && document.framesDone <= obj.Size(end) && isequal(document.inputs, obj.Inputs);
            if tf && ~isempty(obj.MethodRef)
                tf = isfield(document, "method") && isequal(document.method, obj.MethodRef);
            end
        end

        function writer = reopened(obj, done)
            %reopened The output's writer over the file begun, when its adapter can reopen it and it holds the frames done
            writer = [];
            if isempty(obj.Reopen) || ~isfile(obj.OutputPath)
                return
            end
            try
                writer = obj.Reopen();
            catch
                writer = [];
            end
            if ~isempty(writer) && writer.FramesOnDisk < done
                delete(writer);   % the file lacks frames it was said to have (written by a session that died)
                writer = [];
            end
        end
    end

    methods (Static)
        function path = progressPath(path)
            %progressPath The progress document of an output file: <file>.progress.json beside it
            path = string(path) + ".progress.json";
        end

        function value = encode(array)
            %encode An array as {dtype, shape, data}: data is the base64 of its values, little-endian, in
            %column-major order, so it is read back exactly in either language
            className = string(class(array));
            if isempty(array)
                bytes = uint8([]);
            elseif className == "logical"
                bytes = uint8(array(:));
            else
                bytes = typecast(array(:), 'uint8');
            end
            data = '';
            if ~isempty(bytes)
                data = char(matlab.net.base64encode(reshape(bytes, 1, [])));
            end
            value = struct("dtype", char(nansen.Checkpoint.typeName(className)), "shape", size(array), "data", data);
        end

        function array = decode(value)
            className = nansen.Checkpoint.classOf(string(value.dtype));
            shape = double(reshape(value.shape, 1, []));
            if isempty(shape)
                shape = [1, 1];
            elseif isscalar(shape)
                shape = [shape, 1];
            end
            if prod(shape) == 0
                if className == "logical"
                    array = false(shape);
                else
                    array = zeros(shape, char(className));
                end
                return
            end
            bytes = matlab.net.base64decode(string(value.data));
            if className == "logical"
                values = logical(bytes);
            else
                values = typecast(reshape(bytes, 1, []), char(className));
            end
            if numel(values) ~= prod(shape)
                nansen.internal.throwError("invalid-data", "an array of %s holds %d values", mat2str(shape), numel(values))
            end
            array = reshape(values, shape);
        end

        function name = typeName(className)
            %typeName NumPy's name of a class: float64 for double, float32 for single, bool for logical
            names = struct("double", "float64", "single", "float32", "logical", "bool");
            name = string(className);
            if isfield(names, name)
                name = names.(name);
            end
        end

        function className = classOf(name)
            classes = struct("float64", "double", "float32", "single", "bool", "logical");
            className = string(name);
            if isfield(classes, className)
                className = classes.(className);
            end
        end
    end
end
