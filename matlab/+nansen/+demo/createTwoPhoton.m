function project = createTwoPhoton(folder)
%createTwoPhoton Write the two-photon quickstart into an empty folder
%
%   project = nansen.demo.createTwoPhoton(folder) builds what the ophys
%   module's tutorial/ folder describes (tutorial.json, dataset.dsm.json):
%   a SciScan recording of synthetic cells for each session (two subjects
%   with two sessions each), and a project over them, with the core and
%   ophys modules, its tables filled, the ophys variables set up and the
%   frame rate and pixel size read from the recordings. Python's
%   create_two_photon_demo writes the same bytes from the same files.
%
%   Open it in the app with nansen.App(Project=project.Folder).
    arguments
        folder (1,1) string
    end
    if isfolder(folder) && numel(dir(folder)) > 2
        nansen.internal.throwError("folder-not-empty", "%s is not empty", folder)
    end
    tutorialFolder = fullfile(nansen.Module.builtInFolder(), "ophys", "tutorial");
    plan = nansen.internal.readJson(fullfile(tutorialFolder, "tutorial.json"));
    if ~isfolder(folder)
        mkdir(folder);
    end
    copyfile(fullfile(tutorialFolder, "dataset.dsm.json"), fullfile(folder, "dataset.dsm.json"));
    seeds = plan.seeds;
    subjects = reshape(string(fieldnames(plan.subjects)), 1, []);
    for subjectNumber = 1:numel(subjects)
        subject = subjects(subjectNumber);
        fovSeed = seeds.subject * subjectNumber;
        sessions = reshape(string(plan.subjects.(subject)), 1, []);
        for sessionNumber = 1:numel(sessions)
            raw = fullfile(folder, "data", "raw", "sub-" + subject, "ses-" + sessions(sessionNumber));
            mkdir(raw);
            data = syntheticRecording(plan, fovSeed, fovSeed + seeds.session * sessionNumber);
            writeRaw(fullfile(raw, "rec.raw"), data);
            nansen.internal.writeText(fullfile(raw, "rec.ini"), sciscanIni(plan.recording));
        end
    end
    info = plan.project;
    project = nansen.Project.create(folder, info.name, Title=info.title, Dataset="dataset.dsm.json", ...
        Description=info.description);
    project.addModule("core");
    project.addModule("ophys");
    entityTypes = nansen.internal.asCellOfStructs(plan.entityTypes);
    for i = 1:numel(entityTypes)
        project.addEntityType(entityTypes{i}.name, [], Fragments=reshape(string(entityTypes{i}.fragments), 1, []), ...
            Title=entityTypes{i}.title);
    end
    project.scan();
    for i = 1:numel(entityTypes)
        project.sync(entityTypes{i}.name);
    end
    project.runTool("ophys.setup_variables", Options=plan.setup);
    for method = nansen.internal.asCellOfStructs(plan.methods)   % fills the frame rate and pixel size columns from the .ini files
        project.run(method{1}.methodId, project.entities(method{1}.entityType));
    end
    for preset = nansen.internal.asCellOfStructs(plan.presets)
        project.savePreset(preset{1}.methodId, preset{1}.name, preset{1}.values, preset{1}.description);
    end
    project = nansen.Project.open(folder);
end

function text = sciscanIni(recording)
    % The .ini file SciScan writes beside its .raw file, with the frame rate and the FOV (in m)
    fov = string(recording.fov);
    lines = ["[_]", "x.pixels = " + recording.width, "y.pixels = " + recording.height, "no.of.channels = 1", ...
        "no.of.frames.acquired = " + recording.frames, "file.format = 0", "save.ch.1 = ""TRUE""", ...
        "frames.p.sec = """ + string(recording.framesPerSecond) + """", "x.fov = " + fov(1), "y.fov = " + fov(2)];
    text = strjoin(lines, newline) + newline;
end

function writeRaw(path, data)
    % Frame after frame, line after line, big-endian 16-bit integers
    file = fopen(path, "w", "ieee-be");
    if file < 0
        nansen.internal.throwError("cannot-open", "cannot write %s", path)
    end
    closer = onCleanup(@() fclose(file));
    fwrite(file, permute(data, [2, 1, 3]), "uint16");
end

function data = syntheticRecording(plan, fovSeed, seed)
    % A height x width x frames uint16 recording as tutorial.json describes it, with the operations of Python's
    % nansen.demo.synthetic_recording in the same order, so the values are the same
    recording = plan.recording;
    cells = plan.cells;
    background = plan.background;
    height = recording.height;
    width = recording.width;
    frames = recording.frames;
    pad = recording.maxShift;
    sceneHeight = height + 2 * pad;
    sceneWidth = width + 2 * pad;
    rows = (0:sceneHeight - 1)';
    columns = 0:sceneWidth - 1;

    % background: bilinear between hashed values on a grid, and a hashed grain per pixel
    spacing = background.grid;
    stride = floor(sceneWidth / spacing) + 2;
    gy = floor(rows / spacing);
    gx = floor(columns / spacing);
    fy = mod(rows, spacing) / spacing;
    fx = mod(columns, spacing) / spacing;
    corner = @(dy, dx) hashUniform(fovSeed + 2, (gy + dy) * stride + gx + dx);
    coarse = (corner(0, 0) .* (1 - fy) + corner(1, 0) .* fy) .* (1 - fx) + (corner(0, 1) .* (1 - fy) + corner(1, 1) .* fy) .* fx;
    grain = hashUniform(fovSeed + 3, rows * sceneWidth + columns);
    scene = background.level + background.coarse * coarse + background.fine * grain;

    centres = cellCentres(plan, fovSeed) + pad;
    count = size(centres, 1);
    amplitudes = cells.amplitude * (0.5 + hashUniform(fovSeed + 1, 0:count - 1));
    spikes = double(hashUniform(seed, (0:count - 1)' * frames + (0:frames - 1)) < cells.spikeChance);
    calcium = zeros(count, frames);
    level = zeros(count, 1);
    for t = 1:frames
        level = cells.decay * level + spikes(:, t);
        calcium(:, t) = level;
    end

    movie = repmat(scene, 1, 1, frames);
    radius2 = cells.radius * cells.radius;
    for k = 1:count   % one cell at a time, in order
        footprint = max(0, 1 - ((rows - centres(k, 1)) .^ 2 + (columns - centres(k, 2)) .^ 2) / radius2);
        brightness = cells.baseline + amplitudes(k) * calcium(k, :);
        movie = movie + footprint .* reshape(brightness, 1, 1, []);
    end

    % motion: from one frame to the next, a pixel either way along each axis with moveChance, within maxShift
    u = hashUniform(seed + 1, 0:2 * frames - 1);
    chance = recording.moveChance;
    step = @(v) -double(v < chance) + double(v >= 1 - chance);
    shifted = zeros(height, width, frames);
    dy = 0;
    dx = 0;
    for t = 1:frames
        if t > 1
            dy = min(max(dy + step(u(2 * t - 1)), -pad), pad);
            dx = min(max(dx + step(u(2 * t)), -pad), pad);
        end
        shifted(:, :, t) = movie(pad - dy + (1:height), pad - dx + (1:width), t);
    end

    [y, x, t] = ndgrid(0:height - 1, 0:width - 1, 0:frames - 1);
    index = ((t * height + y) * width + x) * 4;
    noise = hashUniform(seed + 2, index);
    for j = 1:3
        noise = noise + hashUniform(seed + 2, index + j);
    end
    noise = (noise - 2) * recording.noise;
    values = floor(shifted + noise + 0.5);
    data = uint16(min(max(values, 0), 65535));
end

function centres = cellCentres(plan, fovSeed)
    % The [row, column] centres (0-based) of a field of view's cells in the frame, one per row: candidate places
    % drawn until count of them are at least minDistance apart
    recording = plan.recording;
    cells = plan.cells;
    centres = zeros(0, 2);
    candidate = 0;
    while size(centres, 1) < cells.count && candidate < 100 * cells.count
        u = hashUniform(fovSeed, [2 * candidate, 2 * candidate + 1]);
        y = cells.margin + floor(u(1) * (recording.height - 2 * cells.margin));
        x = cells.margin + floor(u(2) * (recording.width - 2 * cells.margin));
        candidate = candidate + 1;
        if all((y - centres(:, 1)) .^ 2 + (x - centres(:, 2)) .^ 2 >= cells.minDistance ^ 2)
            centres(end + 1, :) = [y, x]; %#ok<AGROW>
        end
    end
end

function u = hashUniform(seed, index)
    % Numbers in [0, 1) for a seed and integer indexes: the top 24 bits of lowbias32(lowbias32(seed) xor index)
    % over 2^24, exact doubles, as Python's hash_uniform
    hashed = lowbias32(bitxor(lowbias32(uint64(seed)), uint64(index)));
    u = double(bitshift(hashed, -8)) / 16777216;
end

function x = lowbias32(x)
    % The lowbias32 hash of 32-bit integers held in uint64, elementwise: a uint32 product would saturate, so the
    % products are taken in uint64 (below 2^64) and masked to 32 bits
    x = bitxor(x, bitshift(x, -16));
    x = bitand(x .* 0x7feb352du64, 0xFFFFFFFFu64);
    x = bitxor(x, bitshift(x, -15));
    x = bitand(x .* 0x846ca68bu64, 0xFFFFFFFFu64);
    x = bitxor(x, bitshift(x, -16));
end
