function entry = alignmentEntry(alignment, key)
%alignmentEntry The entry of an ROI file's alignment for an entity's key, or [] when it has none
%
%   An ROI file's alignment ({reference, imageSize, entities: [{key,
%   variable, shift, rotation, patches?, rowShifts?, columnShifts?}]}) is
%   written by ophys.alignSessions; an entry is the entity's when the
%   entity's key has each of its key fields. As Python's
%   nansen.frames.alignment_entry.
    entry = [];
    if ~(isstruct(alignment) && isscalar(alignment) && isfield(alignment, "entities"))
        return
    end
    for candidate = nansen.internal.asCellOfStructs(alignment.entities)
        item = candidate{1};
        if ~(isstruct(item) && isfield(item, "key") && isstruct(item.key) && isscalar(item.key))
            continue
        end
        matches = true;
        for name = reshape(string(fieldnames(item.key)), 1, [])
            matches = matches && isfield(key, name) && isequal(string(key.(name)), string(item.key.(name)));
        end
        if matches
            entry = item;
            return
        end
    end
end
