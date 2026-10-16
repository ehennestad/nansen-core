function layout = inspectHdf5(path, limit)
%inspectHdf5 Each group, dataset and link of an HDF5 file (NWB, MATLAB v7.3, .h5), for files.inspect
%
%   The root first, then in path order, as Python's nansen.hdf5.inspect
%   gives them. Shapes are in the file's order (h5info gives them reversed).
    arguments
        path (1,1) string
        limit (1,1) double = 2000
    end
    isHdf5 = false;
    try
        isHdf5 = H5F.is_hdf5(char(path)) > 0;
    catch
    end
    if ~isHdf5
        nansen.internal.throwError("unsupported-file", "%s is not an HDF5 file (NWB, MATLAB v7.3 or .h5)", path)
    end
    info = h5info(path);
    items = walk(path, info, {group(info, "/")});
    paths = strings(1, numel(items));
    for i = 1:numel(items)
        paths(i) = items{i}.path;
    end
    [~, order] = sort(paths);   % code-point order; "/" comes first
    items = items(order);
    layout = struct("format", "hdf5", "truncated", numel(items) > limit);
    layout.items = items(1:min(end, limit));
end

function items = walk(file, info, items)
    parent = string(info.Name);
    for i = 1:numel(info.Datasets)
        items{end + 1} = dataset(file, info.Datasets(i), join(parent, info.Datasets(i).Name)); %#ok<AGROW>
    end
    for i = 1:numel(info.Links)
        link = info.Links(i);
        target = string(link.Value);
        if contains(string(link.Type), "external")
            target = target(1) + ":" + target(end);
        end
        items{end + 1} = struct("path", join(parent, link.Name), "name", string(link.Name), ...
            "kind", "link", "target", target(1)); %#ok<AGROW>
    end
    for i = 1:numel(info.Groups)
        items{end + 1} = group(info.Groups(i), string(info.Groups(i).Name)); %#ok<AGROW>
        items = walk(file, info.Groups(i), items);
    end
end

function full = join(parent, name)
    if parent == "/"
        full = "/" + string(name);
    else
        full = parent + "/" + string(name);
    end
end

function item = group(info, path)
    item = struct("path", path, "name", leaf(path));
    attributes = attributesOf(info.Attributes);
    if isKey(attributes, 'neurodata_type')
        item.neurodataType = attributes('neurodata_type');
    end
    item.kind = "group";
    item.attributes = attributes;
end

function item = dataset(file, info, path)
    item = struct("path", path, "name", leaf(path));
    attributes = attributesOf(info.Attributes);
    if isKey(attributes, 'neurodata_type')
        item.neurodataType = attributes('neurodata_type');
    end
    item.kind = "dataset";
    shape = [];
    if string(info.Dataspace.Type) == "simple"
        shape = fliplr(double(info.Dataspace.Size));
    end
    item.shape = num2cell(shape);
    item.dataType = nansen.internal.hdf5TypeName(info.Datatype);
    if string(info.Dataspace.Type) == "scalar"
        try
            value = plain(h5read(file, path));
            if ~isempty(value)
                item.value = value;
            end
        catch
            % a type h5read cannot read, such as an object reference
        end
    end
    item.attributes = attributes;
end

function name = leaf(path)
    parts = split(path, "/");
    name = parts(end);
    if name == ""
        name = "/";
    end
end

function attributes = attributesOf(list)
    attributes = containers.Map("KeyType", "char", "ValueType", "any");
    for i = 1:numel(list)
        try
            value = plain(list(i).Value);
        catch
            continue
        end
        if ~isempty(value)
            attributes(char(list(i).Name)) = value;
        end
    end
end

function value = plain(value)
    % A single string or number, or [] when it is something else
    if iscell(value) && isscalar(value)
        value = value{1};
    end
    if ischar(value) && (isrow(value) || isempty(value))
        value = string(value);
    end
    if isstring(value) && isscalar(value)
        return
    end
    if (isnumeric(value) || islogical(value)) && isscalar(value)
        if islogical(value)
            return
        end
        value = double(value);
        if ~isfinite(value)
            value = [];
        end
        return
    end
    value = [];
end
