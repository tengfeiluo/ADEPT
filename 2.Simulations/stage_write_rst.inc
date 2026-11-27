# Common end of a resumable chunk: write the restart to a temporary name, then an ".ok" marker holding the step.
# The shell wrapper (Files/stage_resume.sh) renames it to <prefix>_<step>.rst, so a restart is either complete or absent.
write_restart   ${rstprefix}_tmp.rst
print           "$(step)" file ${rstprefix}_tmp.ok
