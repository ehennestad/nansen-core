function out = planFovInventory(inventory, sessions, subjects)
%planFovInventory The FOV map's data from a FOV inventory of NANSEN dev's fovmanager
%
%   out = nansen.legacy.planFovInventory(inventory, sessions, subjects)
%   takes a nansen.legacyFovInventory document (nansen.legacy.
%   exportFovInventory) and the keys (cells of structs) of the sessions (the
%   entity type with FOV positions) and of the subjects (with cranial
%   windows), and returns fovs and windows ({key, values}, the columns of
%   ophys.fov_position and ophys.cranial_window), marks (injections, notes,
%   photos, outlines and headbars: the ophys module's FOV map data), images
%   ({path, image}: BMP files to write, nansen.legacy.writeFovImage),
%   subjects (the keys of the mice found), sessions (the keys of the FOVs
%   placed) and warnings. The rules are those of Python's
%   nansen.fovinventory.plan:
%
%   - a session's FOV is the FOV whose sessions name it: fov_ml and fov_ap
%     (its centre), fov_width_um and fov_height_um (its outline's extent,
%     swapped when the FOV was turned a quarter);
%   - a subject's window is the first window of the mouse of its id (the
%     mouse's id, or m and it): window_ml, window_ap, window_shape (Round
%     2.5mm is round 2.5 mm, dev's trapezoids trapezoid 3 x 5 mm) and
%     window_rotation (dev's theta is clockwise, this counterclockwise); an
%     outline other than the shape's own is an outline of the module's data:
%     an ellipse ([rx, ry], mm) of a round window, else a polygon (mm from
%     the window's centre, before its rotation);
%   - images become BMP files in the project's fovmap folder and photos: a
%     window's over its outline's extent (width, height and offset from its
%     centre), an FOV's (session) in its FOV;
%   - injections are injections, annotations notes, headbar labels headbars.
%
%   Numbers are rounded as floor(v * 10^n + 0.5) / 10^n: in mm to 4
%   decimals, in µm to 3.
    inventory = nansen.internal.jsonRoundTrip(inventory);   % as decoded JSON, whether built in MATLAB or read
    fovs = {};
    windows = {};
    marks = struct("injections", {{}}, "notes", {{}}, "photos", {{}}, "outlines", {{}}, "headbars", {{}});
    images = {};
    warnings = reshape(nansen.internal.asCellstr(nansen.internal.getField(inventory, "skipped", [])), 1, []);
    placed = {};
    placedIds = strings(1, 0);
    found = {};
    foundIds = strings(1, 0);
    windowed = strings(1, 0);
    missing = strings(1, 0);
    twice = strings(1, 0);
    empty = 0;
    for entry = nansen.internal.asCellOfStructs(nansen.internal.getField(inventory, "mice", []))
        mouse = entry{1};
        mouseId = string(mouse.mouseId);
        headbar = string(nansen.internal.getField(mouse, "headbarLabel", ""));
        mouseWindows = nansen.internal.asCellOfStructs(nansen.internal.getField(mouse, "windows", []));
        subject = subjectOf(subjects, mouseId);
        if isempty(subject)
            if ~isempty(mouseWindows) || strlength(headbar) > 0
                warnings{end + 1} = sprintf('mouse %s: no subject of that id; its window and headbar label are left out', mouseId); %#ok<AGROW>
            end
        elseif ~ismember(keyId(subject), foundIds)
            found{end + 1} = subject; %#ok<AGROW>
            foundIds(end + 1) = keyId(subject); %#ok<AGROW>
        end
        if ~isempty(subject) && strlength(headbar) > 0
            marks.headbars{end + 1} = markOf(numel(marks.headbars) + 1, subject, struct("label", char(headbar)));
        end
        extra = 0;
        for w = 1:numel(mouseWindows)
            window = mouseWindows{w};
            center = pointOf(window.center);
            edge = edgeOf(window);
            shape = string(window.shape);
            if ~isempty(subject) && ~ismember(keyId(subject), windowed)
                windowed(end + 1) = keyId(subject); %#ok<AGROW>
                windows{end + 1} = struct("key", subject, "values", windowValues(window, center, shape)); %#ok<AGROW>
                outline = outlineOf(shape, center, edge);
                if ~isempty(outline)
                    marks.outlines{end + 1} = markOf(numel(marks.outlines) + 1, subject, outline);
                end
                photo = windowPhoto(window, center, edge, mouseId);
                if ~isempty(photo)
                    images{end + 1} = struct("path", photo.path, "image", window.image); %#ok<AGROW>
                    marks.photos{end + 1} = markOf(numel(marks.photos) + 1, subject, photo);
                end
            elseif ~isempty(subject)
                extra = extra + 1;
            end
            for f = nansen.internal.asCellOfStructs(nansen.internal.getField(window, "fovs", []))
                fov = f{1};
                fovSessions = string(nansen.internal.asCellstr(nansen.internal.getField(fov, "sessions", [])));
                if isempty(fovSessions)
                    empty = empty + 1;
                    continue
                end
                [width, height] = fovSize(fov);
                pictures = nansen.internal.asCellOfStructs(nansen.internal.getField(fov, "sessionImages", []));
                fovCenter = pointOf(fov.center);
                for sessionId = fovSessions
                    key = sessionOf(sessions, sessionId);
                    if isempty(key)
                        missing(end + 1) = sessionId; %#ok<AGROW>
                        continue
                    end
                    if ismember(keyId(key), placedIds)
                        twice(end + 1) = sessionId; %#ok<AGROW>
                        continue
                    end
                    placed{end + 1} = key; %#ok<AGROW>
                    placedIds(end + 1) = keyId(key); %#ok<AGROW>
                    values = struct("fov_ml", roundTo(fovCenter(1), 4), "fov_ap", roundTo(fovCenter(2), 4));
                    if ~isempty(width)
                        values.fov_width_um = roundTo(width * 1000, 3);
                        values.fov_height_um = roundTo(height * 1000, 3);
                    end
                    fovs{end + 1} = struct("key", key, "values", values); %#ok<AGROW>
                    picture = nansen.internal.getField(fov, "image", []);
                    for p = 1:numel(pictures)
                        if string(pictures{p}.session) == sessionId
                            picture = pictures{p}.image;
                            break
                        end
                    end
                    if ~isempty(picture) && ~isempty(width) && width > 0 && height > 0
                        path = "fovmap/fov-" + fileName(sessionId) + ".bmp";
                        images{end + 1} = struct("path", char(path), "image", picture); %#ok<AGROW>
                        photo = struct("session", key, "path", char(path), "width", roundTo(width, 4), ...
                            "height", roundTo(height, 4), "opacity", 1);
                        marks.photos{end + 1} = markOf(numel(marks.photos) + 1, subject, photo);
                    end
                end
            end
        end
        if extra
            warnings{end + 1} = sprintf('mouse %s: %d more window(s); only the first is placed (the FOVs in them are)', mouseId, extra); %#ok<AGROW>
        end
        for spot = nansen.internal.asCellOfStructs(nansen.internal.getField(mouse, "injections", []))
            marks.injections{end + 1} = markOf(numel(marks.injections) + 1, subject, injectionOf(spot{1}));
        end
        for annotation = nansen.internal.asCellOfStructs(nansen.internal.getField(mouse, "annotations", []))
            at = pointOf(annotation{1}.center);
            text = string(nansen.internal.getField(annotation{1}, "name", ""));
            if strlength(text) == 0
                text = "Annotation";
            end
            note = struct("ml", roundTo(at(1), 4), "ap", roundTo(at(2), 4), "text", char(text));
            marks.notes{end + 1} = markOf(numel(marks.notes) + 1, subject, note);
        end
    end
    if ~isempty(missing)
        warnings{end + 1} = sprintf('FOVs of sessions that are not here, left out: %s', strjoin(missing, ", "));
    end
    if ~isempty(twice)
        warnings{end + 1} = sprintf('sessions in more than one FOV, placed in the first: %s', strjoin(twice, ", "));
    end
    if empty
        warnings{end + 1} = sprintf('%d FOV(s) with no session; left out', empty);
    end
    out = struct("fovs", {fovs}, "windows", {windows}, "marks", marks, "images", {images}, "subjects", {found}, ...
        "sessions", {placed}, "warnings", {warnings});
end

function values = windowValues(window, center, shape)
    shapes = windowShapes();
    windowShape = [];
    if strlength(shape) > 0 && isKey(shapes, char(shape))
        windowShape = shapes(char(shape));
    end
    values = struct("window_ml", roundTo(center(1), 4), "window_ap", roundTo(center(2), 4), ...
        "window_shape", windowShape, "window_rotation", roundTo(mod(-double(window.rotation), 360), 4));
end

function outline = outlineOf(shape, center, edge)
    % The window's outline when it is not its shape's own: an ellipse of a round window, else a polygon
    outline = [];
    if isempty(edge)
        return
    end
    if shape == "Round 2.5mm"
        rx = roundTo((max(edge(:, 1)) - min(edge(:, 1))) / 2, 4);
        ry = roundTo((max(edge(:, 2)) - min(edge(:, 2))) / 2, 4);
        if (rx == 1.25 && ry == 1.25) || ~(rx > 0 && ry > 0)
            return
        end
        outline = struct("ellipse", [rx, ry]);
        return
    end
    points = [roundTo(edge(:, 1) - center(1), 4), roundTo(edge(:, 2) - center(2), 4)];
    if size(points, 1) < 3
        return
    end
    trapezoid = devTrapezoid();
    if strlength(shape) > 0 && isKey(windowShapes(), char(shape)) && (isequal(points, trapezoid) || isequal(points, [trapezoid; trapezoid(1, :)]))
        return
    end
    outline = struct("polygon", {num2cell(points, 2)'});
end

function photo = windowPhoto(window, center, edge, mouseId)
    % A window's photo over its outline's extent, as fovmanager drew it
    photo = [];
    if ~isfield(window, "image") || isempty(edge)
        return
    end
    width = roundTo(max(edge(:, 1)) - min(edge(:, 1)), 4);
    height = roundTo(max(edge(:, 2)) - min(edge(:, 2)), 4);
    if ~(width > 0 && height > 0)
        return
    end
    photo = struct("path", char("fovmap/window-" + fileName(mouseId) + ".bmp"), "width", width, "height", height, ...
        "opacity", 0.6);   % dev's addImage showed a window's photo at 0.6
    offset = [roundTo((min(edge(:, 1)) + max(edge(:, 1))) / 2 - center(1), 4), ...
        roundTo((min(edge(:, 2)) + max(edge(:, 2))) / 2 - center(2), 4)];
    if any(offset ~= 0)
        photo.offset = offset;
    end
end

function [width, height] = fovSize(fov)
    % An FOV's width and height on the map (mm): its outline's extent, swapped when it was turned a quarter
    width = [];
    height = [];
    edge = edgeOf(fov);
    if isempty(edge)
        return
    end
    width = max(edge(:, 1)) - min(edge(:, 1));
    height = max(edge(:, 2)) - min(edge(:, 2));
    if mod(mod(floor(double(fov.rotation) / 90 + 0.5), 4), 2)
        [width, height] = deal(height, width);
    end
end

function mark = injectionOf(spot)
    % An injection as the FOV map keeps one: dev's depth (text) is a number when it is one, else said in what was injected
    at = pointOf(spot.center);
    mark = struct("ml", roundTo(at(1), 4), "ap", roundTo(at(2), 4));
    material = string(nansen.internal.getField(spot, "name", ""));
    depth = nansen.internal.getField(spot, "depth", []);
    number = [];
    if ischar(depth) || isstring(depth)
        text = strtrim(string(depth));
        if ~isempty(regexp(char(text), '^\d+(\.\d+)?$', 'once'))
            number = str2double(text);
        elseif strlength(text) > 0
            material = material + " (" + text + " " + char(181) + "m)";
        end
    elseif isnumeric(depth) && isscalar(depth)
        number = double(depth);
    end
    material = strtrim(material);
    if strlength(material) > 0
        mark.material = char(material);
    end
    if ~isempty(number)
        mark.depth = roundTo(number, 4);
    end
    for name = ["volume", "spread"]
        value = nansen.internal.getField(spot, name, []);
        if isnumeric(value) && isscalar(value)
            mark.(name) = roundTo(double(value), 4);
        end
    end
    colour = colourOf(string(nansen.internal.getField(spot, "color", "")));
    if colour ~= ""
        mark.colour = char(colour);
    end
end

function colour = colourOf(color)
    % dev's colour (a letter, as its Set Color menus set, or the colour's name) as the FOV map's; "" for another
    letters = ["r", "g", "b", "m", "c", "y"];
    names = ["red", "green", "blue", "magenta", "cyan", "yellow"];
    text = lower(strtrim(color));
    colour = "";
    if ismember(text, letters)
        colour = names(letters == text);
    elseif ismember(text, names)
        colour = text;
    end
end

function mark = markOf(id, subject, fields)
    % A mark: its id, its subject (when the mouse's was found), and its fields
    mark = struct("id", id);
    if ~isempty(subject)
        mark.subject = subject;
    end
    for name = reshape(string(fieldnames(fields)), 1, [])
        mark.(name) = fields.(name);
    end
end

function key = subjectOf(subjects, mouseId)
    % The subject of a mouse: of its id, or of m and its id (dev's session ids start with m and the mouse's id)
    key = [];
    for wanted = [mouseId, "m" + mouseId]
        key = keyNaming(subjects, wanted);
        if ~isempty(key)
            return
        end
    end
end

function key = sessionOf(sessions, sessionId)
    key = keyNaming(sessions, sessionId);
end

function key = keyNaming(keys, text)
    % The first key with a text value that is text; [] when none has
    key = [];
    for i = 1:numel(keys)
        for name = reshape(string(fieldnames(keys{i})), 1, [])
            value = keys{i}.(name);
            if (ischar(value) || (isstring(value) && isscalar(value))) && string(value) == text
                key = keys{i};
                return
            end
        end
    end
end

function id = keyId(key)
    id = string(jsonencode(orderfields(key)));
end

function point = pointOf(value)
    point = reshape(double(value), 1, []);
end

function edge = edgeOf(item)
    % An outline's [x, y] points as the rows of an n x 2 array (jsondecode gives one point as a row)
    edge = double(nansen.internal.getField(item, "edge", []));
    if isempty(edge)
        edge = zeros(0, 2);
    elseif isvector(edge) && numel(edge) == 2
        edge = reshape(edge, 1, 2);
    end
end

function value = roundTo(value, digits)
    % floor(v * 10^digits + 0.5) / 10^digits, as Python's nansen.fovinventory rounds
    value = floor(value * 10^digits + 0.5) / 10^digits;
end

function name = fileName(text)
    name = string(regexprep(char(text), '[^A-Za-z0-9_.-]', '_'));
end

function map = windowShapes()
    map = containers.Map({'Round 2.5mm', 'Trapezoidal 3x5mm', 'Custom Trapezoid'}, ...
        {'round 2.5 mm', 'trapezoid 3 x 5 mm', 'trapezoid 3 x 5 mm'});
end

function points = devTrapezoid()
    % dev's CranialWindow.setWindowCoordinates: its trapezoid, 3 mm wide in front and 5 mm behind, 5 mm long
    points = [-1.5, 2.5; -2.5, -2.5; 2.5, -2.5; 1.5, 2.5];
end
