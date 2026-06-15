import sys
import os

target = sys.argv[1] if len(sys.argv) > 1 else "watcher/deploy_watcher.sh"

if not os.path.exists(target):
    print("ERROR: " + target + " not found.")
    sys.exit(1)

with open(target, "r", encoding="utf-8") as f:
    content = f.read()

OLD = (
    'put_param() {\n'
    '  aws $PROFILE_FLAG ssm put-parameter \\\n'
    '    --region "$AWS_REGION" \\\n'
    '    --name "${SSM_PREFIX}/$1" \\\n'
    '    --value "$2" \\\n'
    '    --type "String" \\\n'
    '    --overwrite > /dev/null\n'
    '}'
)

NEW = (
    'put_param() {\n'
    '  local _key="$1" _val="$2"\n'
    '  [[ -z "$_val" ]] && _val="none"\n'
    '  local _esc="${_val//\\\\/\\\\\\\\}"\n'
    '  _esc="${_esc//\\"/\\\\"}"\n'
    '  aws $PROFILE_FLAG ssm put-parameter \\\n'
    '    --region "$AWS_REGION" \\\n'
    '    --cli-input-json "{\\"Name\\":\\"${SSM_PREFIX}/${_key}\\",\\"Value\\":\\"${_esc}\\",\\"Type\\":\\"String\\",\\"Overwrite\\":true}" \\\n'
    '    > /dev/null\n'
    '}'
)

if OLD in content:
    content = content.replace(OLD, NEW, 1)
    with open(target, "w", encoding="utf-8") as f:
        f.write(content)
    print("OK: put_param patched in " + target)
else:
    print("NOT FOUND - use the manual VS Code edit instead.")
    print("Open watcher/deploy_watcher.sh, find the put_param() function")
    print("and replace the --value line with --cli-input-json as shown below:")
    print("")
    print('  aws $PROFILE_FLAG ssm put-parameter \\')
    print('    --region "$AWS_REGION" \\')
    print('    --cli-input-json "{\\"Name\\":\\"${SSM_PREFIX}/${_key}\\",\\"Value\\":\\"${_esc}\\",\\"Type\\":\\"String\\",\\"Overwrite\\":true}" \\')
    print('    > /dev/null')