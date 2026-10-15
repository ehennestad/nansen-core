classdef BinaryStack < nansen.FileAdapter
%BinaryStack NANSEN dev's own image stack file: a headerless .raw (or .bin, .dat) beside an .ini with its Size and Class
%
%   The .ini has two lines, "Size = 512   512  1000" and "Class = uint16";
%   the values are in MATLAB's column-major order, little-endian. A .raw
%   whose .ini is SciScan's is read as SciScan's (ophys.SciScanRaw). Read a
%   chunk of frames at a time, and written in the same format, which dev
%   reads. Python's ophys_adapters.BinaryStack is the same.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            paths = nansen.internal.naturalOrder(paths);
            parts = cell(1, numel(paths));
            for i = 1:numel(paths)
                [dimensions, className] = ophys.BinaryStack.info(paths(i));
                if isempty(dimensions)
                    parts{i} = ophys.SciScanRaw().open(paths(i));
                    continue
                end
                precision = className;
                if className == "logical"
                    precision = "uint8";
                end
                listing = dir(paths(i));
                needed = prod(dimensions) * nansen.StackWriter.bytesOf(precision);
                if listing.bytes < needed
                    nansen.internal.throwError("invalid-data", "%s is %d bytes; Size %s of %s needs %d", paths(i), listing.bytes, mat2str(dimensions), className, needed)
                end
                if numel(dimensions) < 3
                    parts{i} = nansen.Stack.fromArray(nansen.adapters.Npy.readFrames(paths(i), precision, "ieee-le", [dimensions, 1], true, 0, className == "logical", 1, 1), 3);
                    continue
                end
                path = paths(i);
                parts{i} = nansen.Stack(dimensions, className, @(first, last) nansen.adapters.Npy.readFrames( ...
                    path, precision, "ieee-le", dimensions, true, 0, className == "logical", first, last));
            end
            stack = nansen.Stack.join(parts);
        end

        function write(~, path, data)
            if ~(isnumeric(data) || islogical(data)) || ~isreal(data)
                nansen.internal.throwError("invalid-params", "a NANSEN dev binary stack holds real numbers or logical values")
            end
            className = string(class(data));
            ophys.BinaryStack.writeIni(path, size(data), className);
            precision = className;
            if className == "logical"
                precision = "uint8";
            end
            fid = fopen(path, "w", "ieee-le");
            if fid < 0
                nansen.internal.throwError("cannot-open", "cannot write %s", path)
            end
            closer = onCleanup(@() fclose(fid));
            fwrite(fid, data(:), char(precision));
        end

        function writer = create(~, path, dimensions, className)
            %create A writer of a new stack, a chunk of frames at a time, straight into the file
            ophys.BinaryStack.writeIni(path, dimensions, string(className));
            writer = nansen.StackWriter(dimensions, className, Path=path, Header=uint8([]));
        end
    end

    methods (Static)
        function [dimensions, className] = info(path)
            %info Size and class from the .ini; both empty when it is SciScan's
            [folder, name] = fileparts(path);
            ini = fullfile(folder, name + ".ini");
            if ~isfile(ini)
                nansen.internal.throwError("invalid-data", "%s: there is no %s beside it", path, name + ".ini")
            end
            lines = splitlines(string(fileread(ini)));
            keys = strings(0);
            values = strings(0);
            for i = 1:numel(lines)
                parts = split(lines(i), "=");
                if numel(parts) >= 2
                    keys(end + 1) = strtrim(parts(1)); %#ok<AGROW>
                    values(end + 1) = strip(strtrim(join(parts(2:end), "=")), '"'); %#ok<AGROW>
                end
            end
            dimensions = [];
            className = "";
            if ~ismember("Size", keys) || ~ismember("Class", keys)
                if ismember("x.pixels", keys)
                    return
                end
                nansen.internal.throwError("invalid-data", "%s has no Size and Class (not a NANSEN dev binary stack)", ini)
            end
            className = values(find(keys == "Class", 1));
            if ~ismember(className, ["uint8", "int8", "uint16", "int16", "uint32", "int32", "uint64", "int64", "single", "double", "logical"])
                nansen.internal.throwError("invalid-data", "%s: class '%s' is not one this adapter reads", ini, className)
            end
            dimensions = double(str2double(split(strtrim(values(find(keys == "Size", 1))))))';
            dimensions = dimensions(~isnan(dimensions));
        end
    end

    methods (Static, Access = private)
        function writeIni(path, dimensions, className)
            [folder, name] = fileparts(path);
            fid = fopen(fullfile(folder, name + ".ini"), "w");
            closer = onCleanup(@() fclose(fid));
            fprintf(fid, "Size = %s\nClass = %s\n", strjoin(string(dimensions), "  "), className);
        end
    end
end
