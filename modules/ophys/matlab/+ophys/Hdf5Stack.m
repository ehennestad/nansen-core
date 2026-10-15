classdef Hdf5Stack < nansen.FileAdapter
%Hdf5Stack A stack in an HDF5 file: the dataset data (or mov, or the only one of 3 dimensions)
%
%   Frames x height x width as h5py shows it (C order), as suite2p, CaImAn
%   and DeepInterpolation write them; MATLAB sees the dimensions reversed.
%   Read as height x width x frames, a chunk at a time; written as data.
%   Python's ophys_adapters.Hdf5Stack reads and writes the same files.

    methods
        function data = read(obj, path)
            data = all(obj.open(path));
        end

        function stack = open(~, paths)
            paths = nansen.internal.naturalOrder(paths);
            parts = cell(1, numel(paths));
            for i = 1:numel(paths)
                path = paths(i);
                [name, dimensions, className] = ophys.Hdf5Stack.dataset(path);   % [width, height, frames]
                parts{i} = nansen.Stack([dimensions(2), dimensions(1), dimensions(3)], className, ...
                    @(a, b) permute(h5read(path, name, [1, 1, a], [dimensions(1), dimensions(2), b - a + 1]), [2, 1, 3]));
            end
            stack = nansen.Stack.join(parts);
        end

        function write(~, path, data)
            if ndims(data) > 3 || ~(isnumeric(data) || islogical(data))
                nansen.internal.throwError("invalid-params", "an HDF5 stack is height x width x frames")
            end
            if isfile(path)
                delete(path);
            end
            data = permute(data, [2, 1, 3]);
            h5create(path, "/data", size(data, 1:3), Datatype=class(data));
            h5write(path, "/data", data);
        end
    end

    methods (Static, Access = private)
        function [name, dimensions, className] = dataset(path)
            info = h5info(path);
            found = ophys.Hdf5Stack.threeDimensional(info, "");
            names = string({found.name});
            pick = find(ismember(names, ["/data", "/mov", "/mov_data"]), 1);
            if isempty(pick)
                if numel(found) ~= 1
                    nansen.internal.throwError("invalid-data", "%s has no dataset data, and %d of 3 dimensions", path, numel(found))
                end
                pick = 1;
            end
            name = found(pick).name;
            dimensions = found(pick).size;
            className = found(pick).className;
        end

        function found = threeDimensional(group, prefix)
            found = struct("name", {}, "size", {}, "className", {});
            for d = reshape(group.Datasets, 1, [])
                if numel(d.Dataspace.Size) == 3
                    classes = struct("H5T_STD_U8LE", "uint8", "H5T_STD_U16LE", "uint16", "H5T_STD_I16LE", "int16", ...
                        "H5T_STD_U32LE", "uint32", "H5T_STD_I32LE", "int32", "H5T_IEEE_F32LE", "single", "H5T_IEEE_F64LE", "double");
                    className = "double";
                    if isfield(classes, d.Datatype.Type)
                        className = classes.(d.Datatype.Type);
                    end
                    found(end + 1) = struct("name", prefix + "/" + d.Name, "size", reshape(d.Dataspace.Size, 1, 3), "className", className); %#ok<AGROW>
                end
            end
            for g = reshape(group.Groups, 1, [])
                found = [found, ophys.Hdf5Stack.threeDimensional(g, string(g.Name))]; %#ok<AGROW>
            end
        end
    end
end
