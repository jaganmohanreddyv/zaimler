put_param() {
  local _key="$1" _val="$2"
  # SSM rejects empty strings — use placeholder so the key always exists
  [[ -z "$_val" ]] && _val="none"
  # IMPORTANT: Do NOT pass --value "$_val" directly when the value may be an
  # https:// URL. The AWS CLI treats https:// strings in --value as remote URLs
  # to fetch, which returns 403 on API Gateway endpoints and crashes the script.
  # --cli-input-json embeds the value inside JSON, bypassing URI shorthand.
  local _escaped="${_val//\\/\\\\}"    # escape backslashes
  _escaped="${_escaped//\"/\\\"}"      # escape double-quotes
  aws $PROFILE_FLAG ssm put-parameter \
    --region "$AWS_REGION" \
    --cli-input-json "{\"Name\":\"${SSM_PREFIX}/${_key}\",\"Value\":\"${_escaped}\",\"Type\":\"String\",\"Overwrite\":true}" \
    > /dev/null
}