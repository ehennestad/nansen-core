classdef SciScanRaw < nansen.FileAdapter
%SciScanRaw A SciScan .raw file with the .ini file of the same name beside it
%
%   Frames follow each other, with the channels of a frame one after the
%   other; each channel is x.pixels values per line, line after line,
%   big-endian 16-bit integers (file.format 0) or 32-bit floats (1). Reads
%   height x width x frames, or height x width x channels x frames when
%   no.of.channels is more than 1. Frames are counted from the file size
%   when the .ini file does not give no.of.frames.acquired, and an
%   incomplete last frame is left out. Its Metadata: frames.p.sec, the
%   pixel size from x.fov and y.fov, z.spacing of a z-stack, and ZOOM. Python's
%   ophys_adapters.SciScanRaw reads and writes the same files.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            %open The recording as a nansen.Stack read frame by frame from the file; several files are joined
            paths = nansen.internal.naturalOrder(paths);
            parts = cell(1, numel(paths));
            for i = 1:numel(paths)
                parts{i} = ophys.SciScanRaw.openOne(paths(i));
            end
            stack = nansen.Stack.join(parts);
        end

        function write(~, path, data)
            if isa(data, "uint16")
                kind = 0;
            elseif isa(data, "single")
                kind = 1;
            else
                nansen.internal.throwError("invalid-params", "SciScan raw files hold uint16 or single values, not %s", class(data))
            end
            if ndims(data) > 4
                nansen.internal.throwError("invalid-params", "a SciScan stack is height x width x frames, or height x width x channels x frames")
            end
            if ndims(data) <= 3
                data = reshape(data, size(data, 1), size(data, 2), 1, size(data, 3));
            end
            [height, width, channels, frames] = size(data);
            path = string(path);
            fid = fopen(path, "w", "ieee-be");
            if fid < 0
                nansen.internal.throwError("cannot-open", "cannot write %s", path)
            end
            closer = onCleanup(@() fclose(fid));
            fwrite(fid, permute(data, [2, 1, 3, 4]), class(data));
            [folder, name] = fileparts(path);
            lines = ["[_]", "x.pixels = " + width, "y.pixels = " + height, "no.of.channels = " + channels, ...
                "no.of.frames.acquired = " + frames, "file.format = " + kind, ...
                reshape(compose('save.ch.%d = "TRUE"', (1:channels)'), 1, [])];
            nansen.internal.writeText(fullfile(folder, name + ".ini"), strjoin(lines, newline) + newline);
        end
    end

    methods (Static)
        function values = readIni(path)
            %readIni The name = value lines of a SciScan .ini file, values stripped of quotes (the first of a name wins)
            values = containers.Map("KeyType", "char", "ValueType", "char");
            text = fileread(path);
            for line = reshape(splitlines(string(text)), 1, [])
                tokens = regexp(char(line), '^\s*([^=\[;]+?)\s*=\s*"?(.*?)"?\s*$', "tokens", "once");
                if ~isempty(tokens) && ~isKey(values, tokens{1})
                    values(tokens{1}) = tokens{2};
                end
            end
        end
    end

    methods (Static, Access = private)
        function stack = openOne(path)
            [folder, name] = fileparts(path);
            ini = fullfile(folder, name + ".ini");
            if ~isfile(ini)
                nansen.internal.throwError("invalid-data", "%s has no %s.ini beside it", path, name)
            end
            values = ophys.SciScanRaw.readIni(ini);
            width = ophys.SciScanRaw.number(values, "x.pixels", ini);
            height = ophys.SciScanRaw.number(values, "y.pixels", ini);
            channels = 1;
            if isKey(values, "no.of.channels")
                channels = ophys.SciScanRaw.number(values, "no.of.channels", ini);
            end
            kind = ophys.SciScanRaw.number(values, "file.format", ini);
            if kind == 0
                precision = "uint16";
                bytes = 2;
            elseif kind == 1
                precision = "single";
                bytes = 4;
            else
                nansen.internal.throwError("invalid-data", "%s has file.format %d; 0 (16-bit) and 1 (32-bit float) are read", ini, kind)
            end
            perFrame = width * height * channels;
            info = dir(path);
            frames = floor(info.bytes / (perFrame * bytes));
            if isKey(values, "no.of.frames.acquired")
                frames = min(frames, ophys.SciScanRaw.number(values, "no.of.frames.acquired", ini));
            end
            if channels == 1
                dimensions = [height, width, frames];
            else
                dimensions = [height, width, channels, frames];
            end
            stack = nansen.Stack(dimensions, precision, @(first, last) ophys.SciScanRaw.readFrames( ...
                path, precision, width, height, channels, first, last));
            stack.Metadata = ophys.SciScanRaw.metadata(values, width, height);
        end

        function metadata = metadata(values, width, height)
            %metadata frames.p.sec; the pixel size from x.fov and y.fov (in m) over x.pixels and y.pixels; z.spacing for a z-stack (experiment.type XYTZ); ZOOM
            fov = [ophys.SciScanRaw.optional(values, "x.fov"), ophys.SciScanRaw.optional(values, "y.fov")];
            spacing = [];
            if isKey(values, "experiment.type") && string(values("experiment.type")) == "XYTZ"
                spacing = abs(ophys.SciScanRaw.optional(values, "z.spacing"));
            end
            metadata = ophys.internal.stackMetadata(ophys.SciScanRaw.optional(values, "frames.p.sec"), ...
                abs(fov) * 1e6 ./ [width, height], spacing, ophys.SciScanRaw.optional(values, "ZOOM"));
        end

        function value = optional(values, name)
            value = NaN;
            if isKey(values, name)
                value = ophys.internal.textNumber(values(name));
            end
        end

        function data = readFrames(path, precision, width, height, channels, first, last)
            fid = fopen(path, "r", "ieee-be");
            if fid < 0
                nansen.internal.throwError("cannot-open", "cannot open %s", path)
            end
            closer = onCleanup(@() fclose(fid));
            perFrame = width * height * channels;
            fseek(fid, (first - 1) * perFrame * nansen.StackWriter.bytesOf(precision), "bof");
            count = last - first + 1;
            data = fread(fid, count * perFrame, char("*" + precision));
            data = permute(reshape(data, width, height, channels, count), [2, 1, 3, 4]);
            if channels == 1
                data = reshape(data, height, width, count);
            end
        end

        function value = number(values, name, path)
            value = NaN;
            if isKey(values, name)
                value = str2double(strrep(values(name), ",", "."));
            end
            if isnan(value)
                nansen.internal.throwError("invalid-data", "%s has no number %s", path, name)
            end
        end
    end
end
