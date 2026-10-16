function metadata = devStackMetadata(source)
%devStackMetadata What NANSEN dev's metadata file of a data file says of the recording, as a stack's metadata
%
%   metadata = nansen.internal.devStackMetadata(path) reads dev's metadata
%   file beside the data file at path: <name>.yaml, else <name>.yaml.txt
%   (dev's SaveYamlAsTxt), as its adapters' setMetadata and its image stacks
%   (StackMetadata) write them with dev's YAML toolbox. None there, one of
%   more than 4 MB (the frame times of a long recording) or one that is not
%   read (nansen.internal.parseDevYaml) gives struct(). Given the parsed
%   file (a struct) instead of a path, it reads that.
%
%   As Python's nansen.devyaml.stack_metadata, read at the top (dev's
%   StackMetadata), else in the groups Data and Custom (an adapter's
%   setMetadata): frameRate is 1 / TimeIncrement in seconds (1000 / it in
%   milliseconds, 1e6 / it in microseconds; dev's SampleRate), else
%   SampleRate; pixelSize is [PhysicalSizeX, PhysicalSizeY] and zStep
%   PhysicalSizeZ, in µm (their unit a length: micrometer or um,
%   nanometer or nm, millimeter or mm; dev's default, pixel, says nothing).
%   Each is a positive number, rounded to 6 decimals as the stack adapters
%   round theirs (floor(v * 1e6 + 0.5) / 1e6).
    metadata = struct();
    if isstruct(source)
        document = source;
    else
        document = readSidecar(string(source));
    end
    if ~(isstruct(document) && isscalar(document))
        return
    end
    groups = {document};
    for name = ["Data", "Custom"]
        if isfield(document, name) && isstruct(document.(name)) && isscalar(document.(name))
            groups{end + 1} = document.(name); %#ok<AGROW>
        end
    end
    rate = [];
    step = positive(field(groups, "TimeIncrement"));
    unit = field(groups, "TimeIncrementUnit");
    if ~isempty(step) && ischar(unit)
        unit = lower(strtrim(unit));
        if contains(unit, "millisecond") || strcmp(unit, 'ms')
            rate = 1000 / step;
        elseif contains(unit, "microsecond") || any(strcmp(unit, {'us', char([181, 115]), char([956, 115])}))
            rate = 1000000 / step;
        elseif contains(unit, "second") || any(strcmp(unit, {'s', 'sec'}))
            rate = 1 / step;
        end
    end
    if isempty(rate)
        rate = positive(field(groups, "SampleRate"));
    end
    sizes = cell(1, 3);
    axes_ = 'XYZ';
    for k = 1:3
        sizes{k} = micrometers(positive(field(groups, "PhysicalSize" + axes_(k))), field(groups, "PhysicalSize" + axes_(k) + "Unit"));
    end
    rounded = @(v) floor(v * 1e6 + 0.5) / 1e6;
    if ~isempty(rate) && isfinite(rate) && rate > 0
        metadata.frameRate = rounded(rate);
    end
    if ~isempty(sizes{1}) && ~isempty(sizes{2})
        metadata.pixelSize = [rounded(sizes{1}), rounded(sizes{2})];
    end
    if ~isempty(sizes{3})
        metadata.zStep = rounded(sizes{3});
    end
end

function document = readSidecar(path)
    % The parsed metadata file of a data file, or [] when there is none, it is too large or it is not read
    document = [];
    [folder, name] = fileparts(path);
    candidates = [fullfile(folder, name + ".yaml"), fullfile(folder, name + ".yaml.txt")];
    found = candidates(isfile(candidates));
    if isempty(found)
        return
    end
    listing = dir(found(1));
    if listing.bytes > 4 * 1024 * 1024
        return
    end
    try
        document = nansen.internal.parseDevYaml(nansen.internal.readText(found(1)));
    catch err
        if ~isa(err, "nansen.NansenError")
            rethrow(err)
        end
    end
end

function value = field(groups, name)
    % The value of the first group that has the field, or []
    value = [];
    for k = 1:numel(groups)
        if isfield(groups{k}, name)
            value = groups{k}.(name);
            return
        end
    end
end

function value = positive(value)
    % A positive finite number as a double, or []
    if ~(isnumeric(value) && isscalar(value) && isfinite(value) && value > 0)
        value = [];
    else
        value = double(value);
    end
end

function value = micrometers(value, unit)
    % A length in µm, from its unit (a length's; [] for another or none)
    if isempty(value) || ~ischar(unit)
        value = [];
        return
    end
    unit = lower(strtrim(unit));
    micro = {'um', char([181, 109]), char([956, 109]), 'micrometer', 'micrometers', 'micrometre', 'micrometres', ...
        'micron', 'microns'};
    nano = {'nm', 'nanometer', 'nanometers', 'nanometre', 'nanometres'};
    milli = {'mm', 'millimeter', 'millimeters', 'millimetre', 'millimetres'};
    if any(strcmp(unit, micro))
        % as it is
    elseif any(strcmp(unit, nano))
        value = value / 1000;
    elseif any(strcmp(unit, milli))
        value = value * 1000;
    else
        value = [];
        return
    end
    if ~(isfinite(value) && value > 0)
        value = [];
    end
end
