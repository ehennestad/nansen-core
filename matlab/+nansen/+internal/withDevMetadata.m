function stack = withDevMetadata(stack, path)
%withDevMetadata The stack, with what its files do not say of the recording taken from dev's metadata file beside path
%
%   NANSEN dev kept a stack's frame rate, pixel size and plane step, as its
%   Edit Stack Properties set them, in <name>.yaml beside the file
%   (nansen.internal.devStackMetadata); a field the stack's own files give
%   is kept. As Python's nansen.devyaml.with_sidecar.
    extra = nansen.internal.devStackMetadata(path);
    metadata = stack.Metadata;
    for name = reshape(string(fieldnames(extra)), 1, [])
        if ~isfield(metadata, name)
            metadata.(name) = extra.(name);
        end
    end
    stack.Metadata = metadata;
end
