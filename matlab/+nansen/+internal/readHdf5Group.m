function [value, fields] = readHdf5Group(path, group)
%readHdf5Group A group of an HDF5 file as a struct, for files.send (dev's file viewer's NWB node Assign to Workspace,
%which gave a MatNWB object of it)
%
%   [value, fields] = nansen.internal.readHdf5Group(path, group) gives the
%   group's attributes in name order, then its members in name order: a
%   dataset's value (as nansen.internal.readHdf5Dataset reads it) followed
%   by its attributes, as <dataset>_<attribute> (as MatNWB names them:
%   data_unit), a group as a struct of its own, the same way, and a link
%   as the path it points to (file:path for another file's). Fields are
%   made by nansen.internal.hdf5FieldName; fields lists them in order.
%   Attributes that hold object references are left out. As Python's
%   nansen.hdf5.read_group; invalid-params when the file has no group there.
    arguments
        path (1,1) string
        group (1,1) string
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
        info = h5info(path, group);
    catch
        % no such group or dataset
    end
    if isempty(info) || isfield(info, "Dataspace")   % a dataset has a Dataspace
        [~, stem, extension] = fileparts(path);
        nansen.internal.throwError("invalid-params", "%s has no group %s", stem + extension, group)
    end
    [value, fields] = readGroup(path, info);
end

function [value, fields] = readGroup(path, info)
    value = struct();
    fields = strings(1, 0);
    [value, fields] = addAttributes(value, fields, info.Attributes, "");
    groupPath = string(info.Name);
    names = strings(1, 0);
    kinds = strings(1, 0);
    index = zeros(1, 0);
    for k = 1:numel(info.Datasets)
        names(end + 1) = string(info.Datasets(k).Name); %#ok<AGROW>
        kinds(end + 1) = "dataset"; %#ok<AGROW>
        index(end + 1) = k; %#ok<AGROW>
    end
    for k = 1:numel(info.Groups)
        parts = split(string(info.Groups(k).Name), "/");   % h5info names a group by its full path
        names(end + 1) = parts(end); %#ok<AGROW>
        kinds(end + 1) = "group"; %#ok<AGROW>
        index(end + 1) = k; %#ok<AGROW>
    end
    for k = 1:numel(info.Links)
        names(end + 1) = string(info.Links(k).Name); %#ok<AGROW>
        kinds(end + 1) = "link"; %#ok<AGROW>
        index(end + 1) = k; %#ok<AGROW>
    end
    [names, order] = sort(names);
    kinds = kinds(order);
    index = index(order);
    for i = 1:numel(names)
        field = nansen.internal.hdf5FieldName(names(i), fields);
        switch kinds(i)
            case "group"
                value.(field) = readGroup(path, info.Groups(index(i)));
                fields(end + 1) = field; %#ok<AGROW>
            case "link"
                link = info.Links(index(i));
                target = string(link.Value);
                if contains(string(link.Type), "external")
                    target = target(1) + ":" + target(end);
                else
                    target = target(1);
                end
                value.(field) = target;
                fields(end + 1) = field; %#ok<AGROW>
            otherwise
                if groupPath == "/"
                    member = "/" + names(i);
                else
                    member = groupPath + "/" + names(i);
                end
                value.(field) = nansen.internal.readHdf5Dataset(path, member);
                fields(end + 1) = field; %#ok<AGROW>
                [value, fields] = addAttributes(value, fields, info.Datasets(index(i)).Attributes, names(i) + "_");
        end
    end
end

function [value, fields] = addAttributes(value, fields, attributes, prefix)
    % A node's attributes in name order, as fields (prefix before each, for a dataset's in its group); those that hold
    % object references are left out
    if isempty(attributes)
        return
    end
    names = string({attributes.Name});
    [~, order] = sort(names);
    for k = order
        attribute = attributes(k);
        if string(attribute.Datatype.Class) == "H5T_REFERENCE"
            continue
        end
        content = attribute.Value;
        if iscell(content) && isscalar(content)
            content = content{1};
        end
        if ischar(content) && (isrow(content) || isempty(content))
            content = string(content);
        end
        field = nansen.internal.hdf5FieldName(prefix + string(attribute.Name), fields);
        value.(field) = content;
        fields(end + 1) = field; %#ok<AGROW>
    end
end
