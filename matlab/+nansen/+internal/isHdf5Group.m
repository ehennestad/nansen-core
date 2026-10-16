function tf = isHdf5Group(path, node)
%isHdf5Group Whether an HDF5 file has a group at that path (false for a dataset, nothing or a file that is not HDF5),
%as Python's nansen.hdf5.is_group
    arguments
        path (1,1) string
        node (1,1) string
    end
    tf = false;
    try
        if H5F.is_hdf5(char(path)) > 0
            info = h5info(path, node);
            tf = ~isfield(info, "Dataspace");   % a dataset has a Dataspace
        end
    catch
        % not HDF5, or nothing there
    end
end
