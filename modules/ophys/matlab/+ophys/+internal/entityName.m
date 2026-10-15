function name = entityName(entity)
%entityName The entity's key values joined with " / ", for log lines
    name = strjoin(string(struct2cell(entity.Key)), " / ");
end
