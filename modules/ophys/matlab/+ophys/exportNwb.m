function result = exportNwb(entity, options, context)
%exportNwb The recording, its ROIs and their signals in an NWB file (matnwb), as dev's NWBExporter wrote the stack
%
%   The stack is a TwoPhotonSeries in acquisition, written a chunk at a
%   time through a DataPipe; MATLAB's height x width x frames is
%   (frames, x, y) in the file, x the column. The ROIs are a
%   PlaneSegmentation of pixel masks (x, y, weight 1) with their ids and
%   classification; the signals RoiResponseSeries in Fluorescence and
%   DfOverF, linked to the ROIs their columns are. An empty name, or a
%   variable with no file, is left out. A relative path is in the project's
%   folder; {field} tokens are the entity's values. Python's
%   ophys_methods.export_nwb writes the same with pynwb.
    if exist("NwbFile", "class") ~= 8
        nansen.internal.throwError("dependency-missing", "exporting to NWB needs matnwb (github.com/NeurodataWithoutBorders/matnwb) on the path")
    end
    values = entity.values();
    rate = double(options.frameRate);
    if rate <= 0
        rate = double(nansen.internal.getField(values, "frame_rate", 0));
    end
    if ~(isnumeric(rate) && isscalar(rate) && rate > 0)
        nansen.internal.throwError("invalid-options", "give frameRate, or fill in the entity's frame_rate")
    end
    path = fillTokens(string(options.path), values);
    if ~startsWith(path, ["/", "\"]) && isempty(regexp(path, "^[A-Za-z]:", "once"))
        path = fullfile(context.Project.Folder, path);
    end
    if ~isfolder(fileparts(path))
        mkdir(fileparts(path));
    end
    if isfile(path)
        delete(path);
    end

    keyValues = struct2cell(entity.Key);
    description = string(options.sessionDescription);
    if description == ""
        description = ophys.internal.entityName(entity);
    end
    nwb = NwbFile('session_description', char(description), ...
        'identifier', char(strjoin(cellfun(@string, keyValues), "_")), ...
        'session_start_time', sessionStart(values));
    if isfield(values, "session_id")
        nwb.general_session_id = char(string(values.session_id));
    end
    if isfield(values, "subject_id")
        nwb.general_subject = make("core.Subject", "subject_id", char(string(values.subject_id)));
    end
    device = make("core.Device", "description", "two-photon microscope");
    nwb.general_devices.set('Microscope', device);
    optical = make("core.OpticalChannel", "description", sprintf("channel %d", options.channel), "emission_lambda", NaN);
    indicator = string(nansen.internal.getField(values, "indicator", ""));
    if ismissing(indicator) || indicator == ""
        indicator = "unknown";
    end
    plane = make("core.ImagingPlane", "OpticalChannel", optical, "description", "imaging plane", ...
        "device", make("untyped.SoftLink", device), "excitation_lambda", NaN, "imaging_rate", rate, ...
        "indicator", char(indicator), "location", "unknown");
    nwb.general_optophysiology.set('ImagingPlane', plane);
    result = struct("frames", 0, "rois", 0, "signals", {{}});

    stack = readIf(options.stack, @(name) ophys.internal.openStack(context, entity, name, options));
    rest = [];
    if ~isempty(stack)
        [height, width, frames] = size(stack);
        step = ophys.internal.chunk();
        first = stack.frames(1, min(step, frames));
        pipe = make("untyped.DataPipe", "data", first, "maxSize", [height, width, frames], "axis", 3);
        nwb.acquisition.set('TwoPhotonSeries', make("core.TwoPhotonSeries", "imaging_plane", make("untyped.SoftLink", plane), ...
            "starting_time", 0, "starting_time_rate", rate, "data", pipe, "data_unit", "n.a."));
        result.frames = frames;
        rest = min(step, frames) + 1:step:frames;
    end

    document = readIf(options.rois, @(name) context.Project.load(entity, name));
    if ~isempty(document)
        rois = ophys.internal.roiList(document);
        count = numel(rois);
        ids = zeros(count, 1, "int64");
        labels = cell(count, 1);
        x = cell(count, 1);
        y = cell(count, 1);
        for i = 1:count
            ids(i) = nansen.internal.getField(rois{i}, "id", i);
            labels{i} = char(string(nansen.internal.getField(rois{i}, "classification", "")));
            pixels = nansen.internal.roiPixels(rois{i});
            x{i} = uint32(pixels(:, 2));
            y{i} = uint32(pixels(:, 1));
        end
        masks = table(vertcat(x{:}), vertcat(y{:}), ones(numel(vertcat(x{:})), 1, "single"), VariableNames=["x", "y", "weight"]);
        pixelMask = make("hdmf_common.VectorData", "data", masks, "description", "pixel masks: x the column, y the row");
        % the classification column goes in with the others: the table checks its columns as it is made
        segmentation = make("core.PlaneSegmentation", "colnames", {'pixel_mask', 'classification'}, ...
            "description", "ROIs", "imaging_plane", make("untyped.SoftLink", plane), ...
            "id", make("hdmf_common.ElementIdentifiers", "data", ids), ...
            "pixel_mask", pixelMask, ...
            "pixel_mask_index", make("hdmf_common.VectorIndex", "description", "the end of each ROI's pixels", ...
                "target", make("untyped.ObjectView", pixelMask), "data", int64(cumsum(cellfun(@numel, x)))), ...
            "classification", make("hdmf_common.VectorData", "data", labels, ...
                "description", "accepted, rejected, or empty when not classified"));
        images = make("core.ImageSegmentation");
        images.planesegmentation.set('PlaneSegmentation', segmentation);
        module = make("core.ProcessingModule", "description", "ROIs and their signals");
        module.nwbdatainterface.set('ImageSegmentation', images);
        result.rois = count;
        kept = find(~strcmp(labels, "rejected"))' - 1;
        kinds = {"signals", "core.Fluorescence", "Fluorescence", "RoiResponseSeries"; "dff", "core.DfOverF", "DfOverF", "Dff"};
        for k = 1:size(kinds, 1)
            name = string(nansen.internal.getField(options, kinds{k, 1}, ""));
            signals = readIf(name, @(n) double(context.Project.load(entity, n)));
            if isempty(signals)
                continue
            end
            if isvector(signals)
                signals = signals(:);
            end
            if size(signals, 2) == count
                columns = 0:count - 1;
            elseif size(signals, 2) == numel(kept)
                columns = kept;
            else
                nansen.internal.throwError("invalid-data", "%s has %d columns for %d ROIs", name, size(signals, 2), count)
            end
            region = make("hdmf_common.DynamicTableRegion", "table", make("untyped.ObjectView", segmentation), ...
                "description", "the ROIs of the columns", "data", int64(columns(:)));
            series = make("core.RoiResponseSeries", "rois", region, "data", signals', "data_unit", "n.a.", ...
                "starting_time", 0, "starting_time_rate", rate);
            container = make(kinds{k, 2});
            container.roiresponseseries.set(char(kinds{k, 4}), series);
            module.nwbdatainterface.set(char(kinds{k, 3}), container);
            result.signals{end + 1} = char(name);
        end
        nwb.processing.set('ophys', module);
    end

    nwbExport(nwb, char(path));
    if ~isempty(rest)
        written = nwbRead(char(path), 'ignorecache');
        data = written.acquisition.get('TwoPhotonSeries').data;
        for start = rest
            context.checkCancelled();
            last = min(start + ophys.internal.chunk() - 1, result.frames);
            data.append(stack.frames(start, last));
            context.progress(last / result.frames, sprintf("frame %d/%d", last, result.frames));
        end
    end
    context.log("%s: %d frames, %d ROIs and %d signals written to %s", ophys.internal.entityName(entity), ...
        result.frames, result.rois, numel(result.signals), path);
    result.path = char(path);
end

function object = make(kind, varargin)
    % A matnwb type, from types.* (or matnwb.types.* in the versions that moved them there), strings given as char
    persistent prefix
    if isempty(prefix)
        prefix = "types.";
        if exist("matnwb.types.core.NWBFile", "class") == 8
            prefix = "matnwb.types.";
        end
    end
    for i = 1:numel(varargin)   % matnwb keys containers.Map by the names: char, not string
        if isstring(varargin{i}) && isscalar(varargin{i})
            varargin{i} = char(varargin{i});
        end
    end
    object = feval(prefix + kind, varargin{:});
end

function value = readIf(name, reader)
    % What reader gives for the variable, or [] when the name is empty or the entity has no file of it
    value = [];
    if strlength(string(name)) == 0
        return
    end
    try
        value = reader(string(name));
    catch err
        if err.identifier ~= "nansen:DataNotFound"
            rethrow(err)
        end
    end
end

function start = sessionStart(values)
    % The session's start: its session_date (and session_time), else now; in UTC when no time zone is given
    start = datetime("now", TimeZone="UTC");
    text = string(nansen.internal.getField(values, "session_date", ""));
    if ismissing(text) || strlength(text) < 10
        return
    end
    time = string(nansen.internal.getField(values, "session_time", ""));
    try
        if ~ismissing(time) && time ~= ""
            start = datetime(extractBefore(text, 11) + "T" + time, InputFormat="yyyy-MM-dd'T'HH:mm:ss", TimeZone="UTC");
        else
            start = datetime(extractBefore(text, 11), InputFormat="yyyy-MM-dd", TimeZone="UTC");
        end
    catch
    end
end

function text = fillTokens(text, values)
    % The {field} tokens that are fields of values replaced by their value
    tokens = regexp(text, "\{([A-Za-z_]\w*)\}", "tokens");
    for name = unique(string(cellfun(@(t) t{1}, tokens, UniformOutput=false)))
        if isfield(values, name)
            text = replace(text, "{" + name + "}", string(values.(name)));
        end
    end
end
