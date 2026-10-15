function result = exportStack(entity, options, context)
%exportStack Frames firstFrame..lastFrame of the stack written to a file a chunk at a time, as dev's imviewer exports one
%
%   format tiff (a page per frame), binary (dev's .raw beside its .ini),
%   npy, or video (Motion JPEG AVI of 8-bit frames, the values from low to
%   high scaled to 0..255; both 0 for the 0.5th and 99.5th percentiles of
%   the first frames). Frames count from 1; lastFrame 0 is the last. A
%   relative path is in the project's folder; {field} tokens are the
%   entity's values. As Python's ophys_methods.export_stack.
    stack = ophys.internal.openStack(context, entity, options.stack, options);   % frames firstFrame..lastFrame
    frames = size(stack, 3);
    first = double(nansen.internal.getField(options, "firstFrame", 1));
    last = first + frames - 1;
    form = string(nansen.internal.getField(options, "format", "tiff"));
    if ~any(form == ["tiff", "binary", "npy", "video"])
        nansen.internal.throwError("invalid-options", "format is one of tiff, binary, npy, video")
    end
    path = fillTokens(string(options.path), entity.values());
    if ~startsWith(path, ["/", "\"]) && isempty(regexp(path, "^[A-Za-z]:", "once"))
        path = fullfile(context.Project.Folder, path);
    end
    if ~isfolder(fileparts(path))
        mkdir(fileparts(path));
    end
    dimensions = [size(stack, 1), size(stack, 2), frames];
    step = ophys.internal.chunk();
    scale = [];
    switch form
        case "tiff"
            writer = ophys.internal.TiffPageWriter(path, dimensions, stack.ClassName);
        case "binary"
            writer = ophys.BinaryStack().create(path, dimensions, stack.ClassName);
        case "npy"
            writer = nansen.adapters.Npy().create(path, dimensions, stack.ClassName);
        case "video"
            low = double(nansen.internal.getField(options, "low", 0));
            high = double(nansen.internal.getField(options, "high", 0));
            if low == 0 && high == 0
                sample = double(stack.frames(1, step));
                low = ophys.internal.percentileOf(sample(:), 0.5);
                high = ophys.internal.percentileOf(sample(:), 99.5);
            end
            if high <= low
                high = low + 1;
            end
            scale = [low, high];
            writer = VideoWriter(char(path), "Motion JPEG AVI");
            writer.FrameRate = 30;
            writer.Quality = 95;
            open(writer);
    end
    closer = onCleanup(@() close(writer));
    for start = 1:step:frames
        context.checkCancelled();
        stop = min(start + step - 1, frames);
        chunk = stack.frames(start, stop);
        if isempty(scale)
            writer.write(start, chunk);
        else
            scaled = uint8(min(255, max(0, floor((double(chunk) - scale(1)) / (scale(2) - scale(1)) * 255 + 0.5))));
            writeVideo(writer, reshape(scaled, size(scaled, 1), size(scaled, 2), 1, []));
        end
        context.progress(stop / frames, sprintf("frame %d/%d", first + stop - 1, last));
    end
    clear closer   % closes the file
    context.log("%s: frames %d to %d written to %s", ophys.internal.entityName(entity), first, last, path);
    result = struct("frames", frames, "path", char(path), "format", char(form));
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
