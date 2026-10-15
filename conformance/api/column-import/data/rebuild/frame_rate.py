"""A computed column's method, to import: the frame rate of a session, from its id here."""


def run(entity, options, context):
    return {"frame_rate": 30.0 if entity.key["session_id"].endswith("1") else 15.0}
