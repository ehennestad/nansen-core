function result = exportTiff(entity, options, context)
%exportTiff Frames firstFrame..lastFrame of the stack written to a TIFF file, a chunk at a time
%
%   As dev's imviewer exports a stack. Frames count from 1; lastFrame 0 is
%   the last. A relative path is in the project's folder; {field} tokens
%   are the entity's values.
    stack = ophys.internal.openStack(context, entity, options.stack, options);
    frames = size(stack, 3);
    first = double(options.firstFrame);
    last = double(options.lastFrame);
    if last == 0
        last = frames;
    end
    if ~(1 <= first && first <= last && last <= frames)
        nansen.internal.throwError("invalid-options", "frames %d to %d are not frames of the stack's %d", first, last, frames)
    end
    path = fillTokens(string(options.path), entity.values());
    if ~startsWith(path, ["/", "\"]) && isempty(regexp(path, "^[A-Za-z]:", "once"))
        path = fullfile(context.Project.Folder, path);
    end
    folder = fileparts(path);
    if ~isfolder(folder)
        mkdir(folder);
    end
    writer = ophys.internal.TiffPageWriter(path, [size(stack, 1), size(stack, 2), last - first + 1], stack.ClassName);
    closer = onCleanup(@() writer.close());
    step = ophys.internal.chunk();
    for start = first:step:last
        context.checkCancelled();
        stop = min(start + step - 1, last);
        writer.write(start - first + 1, stack.frames(start, stop));
        context.progress((stop - first + 1) / (last - first + 1), sprintf("frame %d/%d", stop, last));
    end
    writer.close();
    context.log("%s: frames %d to %d written to %s", ophys.internal.entityName(entity), first, last, path);
    result = struct("frames", last - first + 1, "path", path);
end

function text = fillTokens(text, values)
    %fillTokens The {field} tokens that are fields of values replaced by their value
    tokens = regexp(text, "\{([A-Za-z_]\w*)\}", "tokens");
    for name = unique(string(cellfun(@(t) t{1}, tokens, UniformOutput=false)))
        if isfield(values, name)
            text = replace(text, "{" + name + "}", string(values.(name)));
        end
    end
end
