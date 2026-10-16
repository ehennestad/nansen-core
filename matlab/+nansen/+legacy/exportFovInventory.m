function inventory = exportFovInventory(path, options)
%exportFovInventory Read a FOV inventory of NANSEN dev's fovmanager into a nansen.legacyFovInventory struct
%
%   inventory = nansen.legacy.exportFovInventory(path) reads the .mat file
%   of fovmanager's Save Fov Inventory (its variable fovDb), without needing
%   dev on the path: each mouse (MouseId, HeadbarLabel), its cranial windows
%   (Windows: shape, center, edge, orientation.theta, the photo of the brain
%   surface in image or brainSurfaceImage, and the fields of view in
%   fovArray: center, edge, orientation.theta, the sessions of
%   listOfSessions (their sessionID and fovImage, or their ids) and
%   currentSession, image or fovImage), injections (Injections: center,
%   name, color, spread, volume, depth) and annotations (Annotations:
%   center, name, color). fovmanager saved these as structs (toStruct), and
%   some as its objects, which load through stand-ins of its map object
%   classes (fovmanager.mapobject.*) when dev is not on the path.
%
%   Images are as fovmanager showed them on the map: mirrored as their
%   orientation says, an FOV's turned (imrotate) a number of quarter turns
%   (floor(theta / 90 + 0.5) mod 4), and upside down (MATLAB draws row 1 at
%   the bottom of the map's axes), as 8-bit RGB: an 8-bit image keeps its
%   values, a logical one is 0 and 255, others are scaled from their
%   smallest to their largest finite value as floor((v - low) / (high - low)
%   * 255 + 0.5). What cannot be read is named in skipped. Python's
%   nansen.fovinventory.normalize reads a file of plain structs the same way.
%
%   exportFovInventory(path, File=out) also writes it as JSON, which
%   legacy.importFovInventory imports in either language.
    arguments
        path (1,1) string
        options.File (1,1) string = ""
    end
    if ~isfile(path)
        nansen.internal.throwError("file-not-found", "no file %s", path)
    end
    stubs = mapObjectStubs(); %#ok<NASGU>   removed when this returns
    state = warning("off", "all");   % dev's objects, and properties the stand-ins do not have
    restore = onCleanup(@() warning(state));
    try
        S = load(path, "-mat", "fovDb");
    catch err
        nansen.internal.throwError("invalid-data", "%s could not be read as a .mat file: %s", path, err.message)
    end
    clear restore
    if ~isfield(S, "fovDb")
        [~, name, extension] = fileparts(path);
        nansen.internal.throwError("invalid-data", "%s has no fovDb: it is not a FOV inventory of dev's fovmanager", ...
            name + extension)
    end
    mice = {};
    skipped = {};
    entries = itemsOf(S.fovDb);
    for index = 1:numel(entries)
        entry = entries{index};
        mouseId = textOf(fieldOf(entry, "MouseId"));
        if isempty(mouseId)
            skipped{end + 1} = sprintf('mouse %d: no MouseId; left out', index); %#ok<AGROW>
            continue
        end
        mouse = struct("mouseId", mouseId, "headbarLabel", textOf(fieldOf(entry, "HeadbarLabel")), ...
            "windows", {{}}, "injections", {{}}, "annotations", {{}});
        windows = itemsOf(fieldOf(entry, "Windows"));
        for number = 1:numel(windows)
            window = windows{number};
            center = pointOf(fieldOf(window, "center"));
            if isempty(center)
                skipped{end + 1} = sprintf('mouse %s: window %d has no center; left out', mouseId, number); %#ok<AGROW>
                continue
            end
            orientation = fieldOf(window, "orientation");
            mirror = [flagOf(fieldOf(orientation, "isMirroredX")), flagOf(fieldOf(orientation, "isMirroredY"))];
            item = struct("shape", textOf(fieldOf(window, "shape")), "center", center, ...
                "edge", {pointsOf(fieldOf(window, "edge"))}, "rotation", rotationOf(orientation));
            image = imageOf(firstOf(window, ["image", "brainSurfaceImage"]), mirror, 0);
            if ~isempty(image)
                item.image = image;
            end
            item.fovs = {};
            fovs = itemsOf(fieldOf(window, "fovArray"));
            for count = 1:numel(fovs)
                fovCenter = pointOf(fieldOf(fovs{count}, "center"));
                if isempty(fovCenter)
                    skipped{end + 1} = sprintf('mouse %s: FOV %d of window %d has no center; left out', ...
                        mouseId, count, number); %#ok<AGROW>
                    continue
                end
                item.fovs{end + 1} = fovOf(fovs{count}, fovCenter);
            end
            mouse.windows{end + 1} = item;
        end
        injections = itemsOf(fieldOf(entry, "Injections"));
        for number = 1:numel(injections)
            injection = injections{number};
            center = pointOf(fieldOf(injection, "center"));
            if isempty(center)
                skipped{end + 1} = sprintf('mouse %s: injection %d has no center; left out', mouseId, number); %#ok<AGROW>
                continue
            end
            spot = struct("center", center);
            for name = ["name", "color"]
                text = textOf(fieldOf(injection, name));
                if ~isempty(text)
                    spot.(name) = text;
                end
            end
            for name = ["spread", "volume"]
                value = numberOf(fieldOf(injection, name));
                if ~isempty(value)
                    spot.(name) = value;
                end
            end
            depth = fieldOf(injection, "depth");
            if ischar(depth) || (isstring(depth) && isscalar(depth))
                if strlength(depth) > 0
                    spot.depth = char(depth);
                end
            elseif ~isempty(numberOf(depth))
                spot.depth = numberOf(depth);
            end
            mouse.injections{end + 1} = spot;
        end
        annotations = itemsOf(fieldOf(entry, "Annotations"));
        for number = 1:numel(annotations)
            annotation = annotations{number};
            center = pointOf(fieldOf(annotation, "center"));
            if isempty(center)
                skipped{end + 1} = sprintf('mouse %s: annotation %d has no center; left out', mouseId, number); %#ok<AGROW>
                continue
            end
            note = struct("center", center);
            for name = ["name", "color"]
                text = textOf(fieldOf(annotation, name));
                if ~isempty(text)
                    note.(name) = text;
                end
            end
            mouse.annotations{end + 1} = note;
        end
        mice{end + 1} = mouse; %#ok<AGROW>
    end
    inventory = struct("schemaType", 'nansen.legacyFovInventory', "schemaVersion", '0.1.0', "source", char(path), ...
        "mice", {mice});
    if ~isempty(skipped)
        inventory.skipped = skipped;
    end
    nansen.checkDocument(inventory, ExpectedType="nansen.legacyFovInventory", Source=path);
    if options.File ~= ""
        nansen.internal.writeJson(options.File, inventory)
    end
end

function item = fovOf(fov, center)
    % An FOV of a window: its place, outline, turn, sessions and images (dev's FoV)
    orientation = fieldOf(fov, "orientation");
    mirror = [flagOf(fieldOf(orientation, "isMirroredX")), flagOf(fieldOf(orientation, "isMirroredY"))];
    rotation = rotationOf(orientation);
    turns = mod(floor(rotation / 90 + 0.5), 4);
    sessions = {};
    images = {};
    entries = itemsOf(fieldOf(fov, "listOfSessions"));   % a struct of each session (sessionID, fovImage), or its id
    for i = 1:numel(entries)
        entry = entries{i};
        if ischar(entry) || (isstring(entry) && isscalar(entry))
            session = char(entry);
            image = [];
        else
            session = textOf(fieldOf(entry, "sessionID"));
            image = fieldOf(entry, "fovImage");
        end
        if isempty(session) || any(strcmp(session, sessions))
            continue
        end
        sessions{end + 1} = session; %#ok<AGROW>
        shown = imageOf(image, mirror, turns);
        if ~isempty(shown)
            images{end + 1} = struct("session", session, "image", shown); %#ok<AGROW>
        end
    end
    current = textOf(fieldOf(fov, "currentSession"));
    if ~isempty(current) && ~any(strcmp(current, sessions))
        sessions{end + 1} = current;
    end
    item = struct("center", center, "edge", {pointsOf(fieldOf(fov, "edge"))}, "rotation", rotation, ...
        "sessions", {sessions});
    image = imageOf(firstOf(fov, ["image", "fovImage"]), mirror, turns);
    if ~isempty(image)
        item.image = image;
    end
    if ~isempty(images)
        item.sessionImages = images;
    end
end

function image = imageOf(value, mirror, turns)
    % An image as fovmanager showed it on the map, as 8-bit RGB ({width, height, pixels}); [] when there is none
    image = [];
    if isempty(value) || ~(isnumeric(value) || islogical(value)) || ~isreal(value) || ndims(value) > 3
        return
    end
    if ndims(value) == 3
        if size(value, 3) >= 3
            value = value(:, :, 1:3);
        else
            return
        end
    end
    if isa(value, "uint8")
        pixels = value;
    elseif islogical(value)
        pixels = uint8(value) * 255;
    else
        values = double(value);
        finite = isfinite(values);
        pixels = zeros(size(values), "uint8");
        if any(finite(:))
            low = min(values(finite));
            high = max(values(finite));
            if high > low
                scaled = floor((values - low) ./ (high - low) .* 255 + 0.5);
                scaled(~finite) = 0;
                pixels = uint8(min(max(scaled, 0), 255));
            end
        end
    end
    if ismatrix(pixels)
        pixels = repmat(pixels, 1, 1, 3);
    end
    if mirror(1)
        pixels = pixels(:, end:-1:1, :);
    end
    if mirror(2)
        pixels = pixels(end:-1:1, :, :);
    end
    pixels = rot90(pixels, turns);
    pixels = pixels(end:-1:1, :, :);
    bytes = reshape(permute(pixels, [3, 2, 1]), 1, []);   % red, green, blue of each pixel, row after row
    image = struct("width", size(pixels, 2), "height", size(pixels, 1), "pixels", char(matlab.net.base64encode(bytes)));
end

function rotation = rotationOf(orientation)
    rotation = numberOf(fieldOf(orientation, "theta"));
    if isempty(rotation)
        rotation = 0;
    end
end

function value = fieldOf(item, name)
    % A field of a struct, or a property of one of fovmanager's objects; [] when it has none
    value = [];
    if isstruct(item) && isscalar(item) && isfield(item, name)
        value = item.(name);
    elseif isobject(item) && isscalar(item) && isprop(item, name)
        value = item.(name);
    end
end

function value = firstOf(item, names)
    value = [];
    for name = names
        value = fieldOf(item, name);
        if ~isempty(value)
            return
        end
    end
end

function items = itemsOf(value)
    % A struct array, object array or cell array as a cell of its items; text as one item
    if isempty(value)
        items = {};
    elseif ischar(value) || (isstring(value) && isscalar(value))
        items = {char(value)};
    elseif iscell(value)
        items = reshape(value, 1, []);
    elseif isstruct(value) || isobject(value)
        items = cell(1, numel(value));
        for i = 1:numel(value)
            items{i} = value(i);
        end
    else
        items = {value};
    end
end

function text = textOf(value)
    % Text, or a whole number as text; '' otherwise
    text = '';
    if ischar(value) && (isrow(value) || isempty(value))
        text = value;
    elseif isstring(value) && isscalar(value) && ~ismissing(value)
        text = char(value);
    else
        number = numberOf(value);
        if ~isempty(number) && number == floor(number) && abs(number) < 2^53
            text = sprintf('%d', number);
        end
    end
end

function number = numberOf(value)
    number = [];
    if isnumeric(value) && isscalar(value) && isreal(value) && isfinite(value)
        number = double(value);
    end
end

function tf = flagOf(value)
    tf = (islogical(value) || isnumeric(value)) && isscalar(value) && value ~= 0;
end

function point = pointOf(value)
    point = [];
    points = pointsOf(value);
    if numel(points) == 1
        point = points{1};
    end
end

function points = pointsOf(value)
    % [x, y] points of an n x 2 array, each a 1 x 2 row (rows with a value that is not finite left out)
    points = {};
    if ~(isnumeric(value) && isreal(value)) || isempty(value) || ndims(value) > 2
        return
    end
    value = double(value);
    if isvector(value) && numel(value) == 2
        value = reshape(value, 1, 2);
    end
    if size(value, 2) ~= 2
        return
    end
    for i = 1:size(value, 1)
        if all(isfinite(value(i, :)))
            points{end + 1} = value(i, :); %#ok<AGROW>
        end
    end
end

function cleanup = mapObjectStubs()
    % Stand-ins of fovmanager's map object classes (fovmanager.mapobject.*), so that an inventory saved with its
    % objects loads without dev, as objects of these with the properties saved. None is made of a class that is on the
    % path (dev's, when dev is). They are written to a temporary folder put on the path, which the returned onCleanup
    % removes again.
    folder = string(tempname);
    added = false;
    base = ["center", "shape", "edge", "image", "alpha", "orientation"];
    classes = { ...
        "BaseObject", "handle", base; ...
        "CranialWindow", "fovmanager.mapobject.BaseObject", ["brainSurfaceAlphaMap", "fovArray", "brainSurfaceImage", "brainSurfaceAlpha"]; ...
        "FoV", "fovmanager.mapobject.BaseObject", ["depth", "nRois", "currentSession", "listOfSessions", "fovImage"]; ...
        "InjectionSpot", "fovmanager.mapobject.BaseObject", ["name", "color", "spread", "volume", "depth", "virusGDocId"]; ...
        "Annotation", "fovmanager.mapobject.BaseObject", ["name", "color", "radius"]};
    if exist("fovmanager.mapobject.BaseObject", "class") == 8
        cleanup = onCleanup(@() []);
        return
    end
    target = fullfile(folder, "+fovmanager", "+mapobject");
    mkdir(target);
    for i = 1:size(classes, 1)
        name = classes{i, 1};
        lines = [
            "classdef " + name + " < " + classes{i, 2}
            "%" + name + " A stand-in of dev's fovmanager.mapobject." + name + " while nansen.legacy.exportFovInventory reads an inventory"
            "    properties"
            "        " + reshape(classes{i, 3}, [], 1)
            "    end"
            "end"];
        nansen.internal.writeText(fullfile(target, name + ".m"), strjoin(lines', newline) + newline);
        added = true;
    end
    if added
        addpath(folder);
    end
    cleanup = onCleanup(@() removeStubs(folder, added));
end

function removeStubs(folder, added)
    if added
        rmpath(folder);
    end
    if isfolder(folder)
        rmdir(folder, "s");
    end
end
