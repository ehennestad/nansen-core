function result = readMetadata(entity, options, context)
%readMetadata The frame rate, pixel size (its width) and z step the recording's files give, written into the entity's columns
%
%   From the stack's Metadata into frame_rate, pixel_size_um and z_step_um,
%   those its table has. Returns them by column. As Python's
%   ophys_methods.read_metadata.
    stack = context.Project.openStack(entity, string(options.stack));
    metadata = stack.Metadata;
    result = struct();
    if isfield(metadata, "frameRate")
        result.frame_rate = metadata.frameRate;
    end
    if isfield(metadata, "pixelSize")
        result.pixel_size_um = metadata.pixelSize(1);
    end
    if isfield(metadata, "zStep")
        result.z_step_um = metadata.zStep;
    end
    written = context.Project.updateValues(entity, result);
    parts = strings(1, numel(written));
    for i = 1:numel(written)
        parts(i) = sprintf("%s %g", written(i), result.(written(i)));
    end
    line = "nothing to write";
    if ~isempty(parts)
        line = strjoin(parts, ", ");
    end
    for name = reshape(setdiff(string(fieldnames(result)), written, "stable"), 1, [])
        line = line + "; no column " + name;
    end
    context.log("%s: %s", ophys.internal.entityName(entity), line);
end
