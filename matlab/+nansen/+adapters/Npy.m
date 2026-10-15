classdef Npy < nansen.FileAdapter
%Npy A NumPy .npy array, read and written without Python
%
%   The array keeps NumPy's shape and indexing: A(i,j,k) is a[i-1,j-1,k-1].
%   A 1-D array reads as a column. Logical, integer and floating point
%   arrays of either byte order are read; arrays are written little-endian
%   in C order, as numpy.save does. Python's nansen.adapters.NpyAdapter
%   reads and writes the same files.

    methods
        function data = read(~, path)
            [precision, byteOrder, shape, fortran, offset, logicalValues] = nansen.adapters.Npy.header(path);
            fid = fopen(path, "r", char(byteOrder));
            closer = onCleanup(@() fclose(fid));
            fseek(fid, offset, "bof");
            count = prod(shape);
            if isempty(shape)
                count = 1;
            end
            values = fread(fid, count, char("*" + precision));
            if numel(values) ~= count
                nansen.internal.throwError("invalid-data", "%s holds fewer values than its shape says", path)
            end
            if logicalValues
                values = logical(values);
            end
            if numel(shape) <= 1
                data = values;   % a scalar, or a 1-D array as a column
                return
            end
            if fortran
                data = reshape(values, shape);
            else
                data = permute(reshape(values, fliplr(shape)), numel(shape):-1:1);
            end
        end

        function stack = open(obj, paths)
            %open The arrays as one nansen.Stack read a chunk of frames at a time; several files are joined
            paths = nansen.internal.naturalOrder(paths);
            parts = cell(1, numel(paths));
            for i = 1:numel(paths)
                [precision, byteOrder, shape, fortran, offset, logicalValues] = nansen.adapters.Npy.header(paths(i));
                if numel(shape) <= 1
                    parts{i} = nansen.Stack.fromArray(obj.read(paths(i)));
                    continue
                end
                className = precision;
                if logicalValues
                    className = "logical";
                end
                path = paths(i);
                parts{i} = nansen.Stack(shape, className, @(first, last) nansen.adapters.Npy.readFrames( ...
                    path, precision, byteOrder, shape, fortran, offset, logicalValues, first, last));
            end
            stack = nansen.Stack.join(parts);
        end

        function writer = create(~, path, dimensions, className)
            %create A writer of a new array, a chunk of frames at a time, straight into the file. Frames are kept
            %together (Fortran order), so a chunk of frames is one stretch of the file to read or write.
            if className == "logical"
                descr = "|b1";
            else
                descr = nansen.adapters.Npy.descrOf(cast(0, char(className)));
            end
            shapeText = "(" + strjoin(string(dimensions), ", ") + ")";
            if isscalar(dimensions)
                shapeText = "(" + dimensions + ",)";
            end
            text = "{'descr': '" + descr + "', 'fortran_order': True, 'shape': " + shapeText + ", }";
            total = 10 + strlength(text) + 1;
            text = text + string(repmat(' ', 1, mod(64 - mod(total, 64), 64))) + newline;
            header = [uint8([147, 'NUMPY', 1, 0]), typecast(uint16(strlength(text)), "uint8"), uint8(char(text))];
            writer = nansen.StackWriter(dimensions, className, Path=path, Header=header);
        end

        function writer = reopen(~, path, dimensions, className)
            %reopen A writer that goes on writing into an array file create began (nansen.Checkpoint): [] unless the
            %file is an array of this size and class, frames together, little-endian. Its FramesOnDisk is how many
            %frames the file holds (a writer that stopped wrote those in order).
            writer = [];
            [precision, byteOrder, shape, fortran, offset, logicalValues] = nansen.adapters.Npy.header(path);
            found = string(precision);
            if logicalValues
                found = "logical";
            end
            if ~fortran || byteOrder ~= "ieee-le" || found ~= string(className) || ~isequal(double(shape(:)'), double(dimensions))
                return
            end
            writer = nansen.StackWriter(dimensions, className, Path=path, Reopen=true, Offset=offset);
        end

        function write(~, path, data)
            if ~(isnumeric(data) || islogical(data)) || ~isreal(data)
                nansen.internal.throwError("invalid-params", "the npy adapter writes real numeric or logical arrays")
            end
            descr = nansen.adapters.Npy.descrOf(data);
            shape = size(data);
            if isscalar(data)
                shapeText = "()";
            else
                shapeText = "(" + strjoin(string(shape), ", ") + ")";
            end
            header = "{'descr': '" + descr + "', 'fortran_order': False, 'shape': " + shapeText + ", }";
            % magic (6) + version (2) + length (2) + header, padded with spaces to a multiple of 64 and ending in a newline
            total = 10 + strlength(header) + 1;
            header = header + string(repmat(' ', 1, mod(64 - mod(total, 64), 64))) + newline;
            fid = fopen(path, "w", "ieee-le");
            if fid < 0
                nansen.internal.throwError("cannot-open", "cannot write %s", path)
            end
            closer = onCleanup(@() fclose(fid));
            fwrite(fid, uint8([147, 'NUMPY', 1, 0]), "uint8");
            fwrite(fid, strlength(header), "uint16");
            fwrite(fid, char(header), "char");
            if ndims(data) > 1 && ~isscalar(data)
                data = permute(data, ndims(data):-1:1);   % C order: the last index varies fastest
            end
            if islogical(data)
                fwrite(fid, uint8(data(:)), "uint8");
            else
                fwrite(fid, data(:), class(data));
            end
        end
    end

    methods (Static)
        function [precision, byteOrder, shape, fortran, offset, logicalValues] = header(path)
            %header What a .npy file's header says: the values' class and byte order, the shape, whether in
            %Fortran order, where the values begin, and whether they are booleans
            fid = fopen(path, "r", "ieee-le");
            if fid < 0
                nansen.internal.throwError("cannot-open", "cannot open %s", path)
            end
            closer = onCleanup(@() fclose(fid));
            magic = fread(fid, 6, "*uint8")';
            if ~isequal(magic, uint8([147, 'NUMPY']))
                nansen.internal.throwError("invalid-data", "%s is not a .npy file", path)
            end
            version = fread(fid, 2, "*uint8")';
            if version(1) == 1
                headerLength = double(fread(fid, 1, "uint16"));
                offset = 10 + headerLength;
            else
                headerLength = double(fread(fid, 1, "uint32"));
                offset = 12 + headerLength;
            end
            text = char(fread(fid, headerLength, "*uint8")');
            descr = regexp(text, "'descr'\s*:\s*'([^']*)'", "tokens", "once");
            fortranText = regexp(text, "'fortran_order'\s*:\s*(True|False)", "tokens", "once");
            shapeText = regexp(text, "'shape'\s*:\s*\(([^)]*)\)", "tokens", "once");
            if isempty(descr) || isempty(fortranText) || isempty(shapeText)
                nansen.internal.throwError("invalid-data", "%s has a .npy header this reader does not understand", path)
            end
            shape = str2double(strtrim(split(string(shapeText{1}), ",")))';
            shape = shape(~isnan(shape));
            [precision, byteOrder] = nansen.adapters.Npy.precisionOf(descr{1}, path);
            fortran = fortranText{1} == "True";
            logicalValues = precision == "uint8" && startsWith(descr{1}, ["|b1", "<b1", ">b1"]);
        end
    end

    methods (Static, Hidden)   % used by other adapters of raw values too (ophys.BinaryStack)
        function data = readFrames(path, precision, byteOrder, shape, fortran, offset, logicalValues, first, last)
            %readFrames Frames first..last of an array of the shape, frames last: one stretch of the file in Fortran
            %order; in C order a run of values for each pixel, the rest skipped
            fid = fopen(path, "r", char(byteOrder));
            if fid < 0
                nansen.internal.throwError("cannot-open", "cannot open %s", path)
            end
            closer = onCleanup(@() fclose(fid));
            bytes = nansen.StackWriter.bytesOf(precision);
            frameSize = shape(1:end - 1);
            perFrame = prod(frameSize);
            count = last - first + 1;
            if fortran
                fseek(fid, offset + (first - 1) * perFrame * bytes, "bof");
                values = fread(fid, perFrame * count, char("*" + precision));
                data = reshape(values, [frameSize, count]);
            else
                fseek(fid, offset + (first - 1) * bytes, "bof");
                values = fread(fid, perFrame * count, char(count + "*" + precision + "=>" + precision), (shape(end) - count) * bytes);
                data = permute(reshape(values, [count, fliplr(frameSize)]), numel(shape):-1:1);
            end
            if logicalValues
                data = logical(data);
            end
        end

        function [precision, byteOrder] = precisionOf(descr, path)
            byteOrder = "ieee-le";
            if startsWith(descr, ">")
                byteOrder = "ieee-be";
            end
            kinds = struct("b1", "uint8", "u1", "uint8", "i1", "int8", "u2", "uint16", "i2", "int16", ...
                "u4", "uint32", "i4", "int32", "u8", "uint64", "i8", "int64", "f4", "single", "f8", "double");
            code = string(descr(2:end));
            if ~isfield(kinds, code)
                nansen.internal.throwError("invalid-data", "%s holds %s values, which this reader does not read", path, descr)
            end
            precision = kinds.(code);
        end

        function descr = descrOf(data)
            codes = struct("logical", "|b1", "uint8", "|u1", "int8", "|i1", "uint16", "<u2", "int16", "<i2", ...
                "uint32", "<u4", "int32", "<i4", "uint64", "<u8", "int64", "<i8", "single", "<f4", "double", "<f8");
            descr = codes.(class(data));
        end
    end
end
