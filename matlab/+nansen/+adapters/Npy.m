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
            else
                headerLength = double(fread(fid, 1, "uint32"));
            end
            header = char(fread(fid, headerLength, "*uint8")');
            descr = regexp(header, "'descr'\s*:\s*'([^']*)'", "tokens", "once");
            fortran = regexp(header, "'fortran_order'\s*:\s*(True|False)", "tokens", "once");
            shapeText = regexp(header, "'shape'\s*:\s*\(([^)]*)\)", "tokens", "once");
            if isempty(descr) || isempty(fortran) || isempty(shapeText)
                nansen.internal.throwError("invalid-data", "%s has a .npy header this reader does not understand", path)
            end
            shape = str2double(strtrim(split(string(shapeText{1}), ",")))';
            shape = shape(~isnan(shape));
            [precision, byteOrder] = nansen.adapters.Npy.precisionOf(descr{1}, path);
            count = prod(shape);
            if isempty(shape)
                count = 1;
            end
            values = fread(fid, count, char("*" + precision), 0, char(byteOrder));
            if numel(values) ~= count
                nansen.internal.throwError("invalid-data", "%s holds fewer values than its shape says", path)
            end
            if precision == "uint8" && startsWith(descr{1}, ["|b1", "<b1", ">b1"])
                values = logical(values);
            end
            if numel(shape) <= 1
                data = values;   % a scalar, or a 1-D array as a column
                return
            end
            if fortran{1} == "True"
                data = reshape(values, shape);
            else
                data = permute(reshape(values, fliplr(shape)), numel(shape):-1:1);
            end
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

    methods (Static, Access = private)
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
