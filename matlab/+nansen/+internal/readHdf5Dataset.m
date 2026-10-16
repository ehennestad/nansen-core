function [value, shape, typeName] = readHdf5Dataset(path, dataset)
%readHdf5Dataset One dataset of an HDF5 file, for files.send (dev's file viewer's NWB node Assign to Workspace)
%
%   [value, shape, typeName] = nansen.internal.readHdf5Dataset(path, dataset)
%   gives what h5read reads (in MATLAB's order: the file's dimensions
%   reversed; a string as a string), the shape in the file's order and the
%   shared name of its type, as Python's nansen.hdf5.read_dataset.
%   invalid-params when the file has no dataset at that path.
    arguments
        path (1,1) string
        dataset (1,1) string
    end
    isHdf5 = false;
    try
        isHdf5 = H5F.is_hdf5(char(path)) > 0;
    catch
    end
    if ~isHdf5
        nansen.internal.throwError("unsupported-file", "%s is not an HDF5 file (NWB, MATLAB v7.3 or .h5)", path)
    end
    info = [];
    try
        info = h5info(path, dataset);
    catch
        % no such group or dataset
    end
    [~, stem, extension] = fileparts(path);
    if isempty(info) || ~isfield(info, "Dataspace")   % a group has no Dataspace
        nansen.internal.throwError("invalid-params", "%s has no dataset %s", stem + extension, dataset)
    end
    shape = zeros(1, 0);
    if string(info.Dataspace.Type) == "simple"
        shape = fliplr(double(info.Dataspace.Size));
    end
    typeName = nansen.internal.hdf5TypeName(info.Datatype);
    value = h5read(path, dataset);
    if iscell(value) && isscalar(value)
        value = value{1};
    end
    if ischar(value) && (isrow(value) || isempty(value))
        value = string(value);
    end
end
