#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 配置文件路径
CONFIG_DIR="$HOME/.aws-mfa"
CONFIG_FILE="$CONFIG_DIR/config"
IAM_USER_FILE="$CONFIG_DIR/iam_user"

# 默认配置
MFA_SERIAL=""
DURATION=43200
AWS_PROFILE="default"
REGION="us-east-1"

# 创建配置目录
mkdir -p "$CONFIG_DIR"

# 读取配置文件（如果存在）
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 读取IAM用户信息（如果存在）
if [ -f "$IAM_USER_FILE" ]; then
    source "$IAM_USER_FILE"
fi

# 处理命令行参数
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --mfa-serial)
            MFA_SERIAL="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --save-config)
            SAVE_CONFIG=true
            shift
            ;;
        --update-credentials)
            UPDATE_CREDENTIALS=true
            shift
            ;;
        --setup)
            SETUP=true
            shift
            ;;
        --help)
            echo "用法: $(basename $0) [选项]"
            echo "选项:"
            echo "  --mfa-serial ARN     设置MFA设备ARN"
            echo "  --duration SECONDS   设置会话持续时间（秒，最大43200）"
            echo "  --profile NAME       设置AWS配置文件名称"
            echo "  --region REGION      设置AWS区域"
            echo "  --save-config        保存当前配置为默认值"
            echo "  --update-credentials 更新长期凭证"
            echo "  --setup              重新进行初始设置"
            echo "  --help               显示此帮助信息"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

# 清除屏幕
clear

echo -e "${BLUE}==============================================${NC}"
echo -e "${BLUE}      AWS MFA 临时凭证一键获取脚本 (通用版)    ${NC}"
echo -e "${BLUE}==============================================${NC}"

# 检查是否安装了必要的工具
for cmd in aws jq; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}错误: 缺少必要的命令 '$cmd'${NC}"
        echo "请安装必要的工具: "
        echo "  - AWS CLI: https://aws.amazon.com/cli/"
        echo "  - jq: 'brew install jq' 或 'apt install jq'"
        exit 1
    fi
done

# 通过IAM获取用户信息和MFA设备
get_iam_info() {
    echo -e "\n${YELLOW}正在尝试获取用户信息...${NC}"
    IAM_INFO=$(aws iam get-user 2>&1)
    if [ $? -ne 0 ]; then
        if [[ "$IAM_INFO" == *"authorization"* ]] || [[ "$IAM_INFO" == *"AccessDenied"* ]]; then
            echo -e "${YELLOW}无权限获取IAM用户信息，需要手动配置${NC}"
            return 1
        else
            echo -e "${RED}获取用户信息失败: $IAM_INFO${NC}"
            return 1
        fi
    fi
    
    # 提取用户名和ARN
    IAM_USERNAME=$(echo $IAM_INFO | jq -r '.User.UserName')
    IAM_USER_ARN=$(echo $IAM_INFO | jq -r '.User.Arn')
    IAM_ACCOUNT=$(echo $IAM_USER_ARN | cut -d':' -f5)
    
    echo -e "${GREEN}已检测到IAM用户:${NC}"
    echo -e "用户名: ${YELLOW}$IAM_USERNAME${NC}"
    echo -e "账户ID: ${YELLOW}$IAM_ACCOUNT${NC}"
    
    # 尝试获取MFA设备
    MFA_DEVICES=$(aws iam list-mfa-devices --user-name "$IAM_USERNAME" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}无法获取MFA设备列表: $MFA_DEVICES${NC}"
        return 1
    fi
    
    MFA_COUNT=$(echo $MFA_DEVICES | jq -r '.MFADevices | length')
    if [ "$MFA_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}未找到MFA设备。请先为您的账户启用MFA。${NC}"
        return 1
    elif [ "$MFA_COUNT" -eq 1 ]; then
        DETECTED_MFA_SERIAL=$(echo $MFA_DEVICES | jq -r '.MFADevices[0].SerialNumber')
        echo -e "已检测到MFA设备: ${YELLOW}$DETECTED_MFA_SERIAL${NC}"
        
        # 保存IAM信息
        echo "# AWS MFA IAM用户信息" > "$IAM_USER_FILE"
        echo "IAM_USERNAME=\"$IAM_USERNAME\"" >> "$IAM_USER_FILE"
        echo "IAM_USER_ARN=\"$IAM_USER_ARN\"" >> "$IAM_USER_FILE"
        echo "IAM_ACCOUNT=\"$IAM_ACCOUNT\"" >> "$IAM_USER_FILE"
        echo "DETECTED_MFA_SERIAL=\"$DETECTED_MFA_SERIAL\"" >> "$IAM_USER_FILE"
        
        return 0
    else
        echo -e "${YELLOW}检测到多个MFA设备:${NC}"
        echo $MFA_DEVICES | jq -r '.MFADevices[].SerialNumber' | nl
        return 1
    fi
}

# 初始化设置
setup_config() {
    echo -e "\n${BLUE}===== 初始设置 =====${NC}"
    
    # 尝试自动检测IAM信息
    if get_iam_info; then
        echo -e "\n${GREEN}成功检测到IAM用户和MFA设备!${NC}"
        
        # 询问是否使用检测到的MFA设备
        read -p "是否使用检测到的MFA设备? (y/n) [y]: " USE_DETECTED
        USE_DETECTED=${USE_DETECTED:-y}
        
        if [[ $USE_DETECTED =~ ^[Yy]$ ]]; then
            MFA_SERIAL="$DETECTED_MFA_SERIAL"
        fi
    else
        echo -e "\n${YELLOW}无法自动检测配置，请手动设置${NC}"
    fi
    
    # 如果MFA_SERIAL为空，请求手动输入
    if [ -z "$MFA_SERIAL" ]; then
        echo -e "\n请输入MFA设备ARN或序列号。格式示例:"
        echo "虚拟MFA: arn:aws:iam::123456789012:mfa/username"
        echo "硬件MFA: arn:aws:iam::123456789012:mfa/GAHT12345678"
        
        read -p "MFA设备ARN/序列号: " MFA_SERIAL
        
        while [ -z "$MFA_SERIAL" ]; do
            echo -e "${RED}MFA设备ARN不能为空!${NC}"
            read -p "MFA设备ARN/序列号: " MFA_SERIAL
        done
    fi
    
    # 确认其他设置
    read -p "AWS配置文件名称 [$AWS_PROFILE]: " INPUT_PROFILE
    AWS_PROFILE=${INPUT_PROFILE:-$AWS_PROFILE}
    
    read -p "AWS区域 [$REGION]: " INPUT_REGION
    REGION=${INPUT_REGION:-$REGION}
    
    read -p "临时凭证有效期(秒) [$DURATION]: " INPUT_DURATION
    DURATION=${INPUT_DURATION:-$DURATION}
    
    # 确认设置
    echo -e "\n${YELLOW}配置确认:${NC}"
    echo -e "MFA设备ARN: ${BLUE}$MFA_SERIAL${NC}"
    echo -e "AWS配置文件: ${BLUE}$AWS_PROFILE${NC}"
    echo -e "AWS区域: ${BLUE}$REGION${NC}"
    echo -e "会话持续时间: ${BLUE}$DURATION 秒${NC}"
    
    read -p "保存配置? (y/n) [y]: " SAVE_CONFIRM
    SAVE_CONFIRM=${SAVE_CONFIRM:-y}
    
    if [[ $SAVE_CONFIRM =~ ^[Yy]$ ]]; then
        # 保存配置
        echo "# AWS MFA脚本配置文件" > "$CONFIG_FILE"
        echo "MFA_SERIAL=\"$MFA_SERIAL\"" >> "$CONFIG_FILE"
        echo "DURATION=$DURATION" >> "$CONFIG_FILE"
        echo "AWS_PROFILE=\"$AWS_PROFILE\"" >> "$CONFIG_FILE"
        echo "REGION=\"$REGION\"" >> "$CONFIG_FILE"
        echo -e "${GREEN}配置已保存!${NC}"
    fi
}

# 更新长期凭证
update_long_term_credentials() {
    echo -e "\n${YELLOW}更新长期凭证...${NC}"
    
    # 显示当前配置
    CURRENT_KEY=$(aws configure get aws_access_key_id --profile "$AWS_PROFILE")
    if [ -n "$CURRENT_KEY" ]; then
        echo -e "当前访问密钥ID: ${BLUE}${CURRENT_KEY:0:4}...${CURRENT_KEY: -4}${NC} (配置文件: $AWS_PROFILE)"
    else
        echo -e "${YELLOW}当前没有配置访问密钥${NC}"
    fi
    
    # 输入新凭证
    echo -e "\n请输入新的长期凭证:"
    read -p "AWS Access Key ID: " NEW_ACCESS_KEY
    read -p "AWS Secret Access Key: " NEW_SECRET_KEY
    
    # 验证输入不为空
    if [ -z "$NEW_ACCESS_KEY" ] || [ -z "$NEW_SECRET_KEY" ]; then
        echo -e "${RED}错误: 凭证不能为空${NC}"
        return 1
    fi
    
    # 验证密钥格式
    if ! [[ $NEW_ACCESS_KEY =~ ^[A-Z0-9]{20}$ ]]; then
        echo -e "${YELLOW}警告: 访问密钥ID格式可能不正确 (应为20个字符)${NC}"
        read -p "继续? (y/n) [y]: " CONTINUE
        if [[ ! $CONTINUE =~ ^[Yy]$ ]] && [[ $CONTINUE != "" ]]; then
            return 1
        fi
    fi
    
    # 更新配置文件
    aws configure set aws_access_key_id "$NEW_ACCESS_KEY" --profile "$AWS_PROFILE"
    aws configure set aws_secret_access_key "$NEW_SECRET_KEY" --profile "$AWS_PROFILE"
    aws configure set aws_session_token "" --profile "$AWS_PROFILE"
    aws configure set region "$REGION" --profile "$AWS_PROFILE"
    
    echo -e "${GREEN}长期凭证已更新!${NC}"
    
    # 测试新凭证
    echo -e "\n${YELLOW}验证新的长期凭证...${NC}"
    TEST_RESULT=$(AWS_PROFILE="$AWS_PROFILE" aws sts get-caller-identity 2>&1)
    if [ $? -eq 0 ]; then
        ACCOUNT_ID=$(echo $TEST_RESULT | jq -r '.Account')
        USER_ARN=$(echo $TEST_RESULT | jq -r '.Arn')
        echo -e "${GREEN}凭证验证成功!${NC}"
        echo -e "账户ID: ${YELLOW}$ACCOUNT_ID${NC}"
        echo -e "用户ARN: ${YELLOW}$USER_ARN${NC}"
        
        # 检查MFA设备ARN与账户是否匹配
        if [[ "$MFA_SERIAL" == *":mfa/"* ]]; then
            MFA_ACCOUNT=$(echo $MFA_SERIAL | cut -d':' -f5)
            if [ "$MFA_ACCOUNT" != "$ACCOUNT_ID" ]; then
                echo -e "${YELLOW}警告: MFA设备ARN中的账户ID ($MFA_ACCOUNT) 与您的账户 ($ACCOUNT_ID) 不匹配${NC}"
                echo -e "您可能需要更新MFA设备ARN为: ${BLUE}arn:aws:iam::${ACCOUNT_ID}:mfa/$(echo $MFA_SERIAL | cut -d'/' -f2)${NC}"
                
                read -p "是否自动更新MFA设备ARN? (y/n) [y]: " UPDATE_MFA
                UPDATE_MFA=${UPDATE_MFA:-y}
                if [[ $UPDATE_MFA =~ ^[Yy]$ ]]; then
                    MFA_SERIAL="arn:aws:iam::${ACCOUNT_ID}:mfa/$(echo $MFA_SERIAL | cut -d'/' -f2)"
                    echo -e "${GREEN}已更新MFA设备ARN为: ${BLUE}$MFA_SERIAL${NC}"
                    
                    # 保存更新的MFA ARN
                    if [ -f "$CONFIG_FILE" ]; then
                        sed -i.bak "s|MFA_SERIAL=.*|MFA_SERIAL=\"$MFA_SERIAL\"|g" "$CONFIG_FILE" 2>/dev/null || 
                        sed -i "s|MFA_SERIAL=.*|MFA_SERIAL=\"$MFA_SERIAL\"|g" "$CONFIG_FILE"
                    fi
                fi
            fi
        fi
    else
        echo -e "${RED}凭证验证失败:${NC}"
        echo -e "${RED}$TEST_RESULT${NC}"
        echo -e "\n${YELLOW}请检查您输入的凭证是否正确。您仍然可以尝试使用这些凭证请求临时令牌。${NC}"
    fi
    
    return 0
}

# 第一次运行或请求设置时执行初始化
if [ -z "$MFA_SERIAL" ] || [ "$SETUP" = true ]; then
    setup_config
fi

# 如果请求更新长期凭证
if [ "$UPDATE_CREDENTIALS" = true ]; then
    update_long_term_credentials
    if [ $? -ne 0 ]; then
        echo -e "${RED}凭证更新失败${NC}"
        exit 1
    fi
fi

# 检查MFA_SERIAL是否设置
if [ -z "$MFA_SERIAL" ]; then
    echo -e "${RED}错误: MFA设备ARN未设置!${NC}"
    echo -e "请使用 --setup 选项设置MFA设备ARN，或使用 --mfa-serial 指定ARN。"
    exit 1
fi

# 显示当前配置
echo -e "\n${YELLOW}当前配置:${NC}"
echo -e "MFA设备ARN: ${BLUE}$MFA_SERIAL${NC}"
echo -e "会话持续时间: ${BLUE}$DURATION 秒${NC}"
echo -e "AWS配置文件: ${BLUE}$AWS_PROFILE${NC}"
echo -e "AWS区域: ${BLUE}$REGION${NC}"

# 保存配置（如果请求）
if [ "$SAVE_CONFIG" = true ]; then
    mkdir -p $(dirname "$CONFIG_FILE")
    echo "# AWS MFA脚本配置文件" > "$CONFIG_FILE"
    echo "MFA_SERIAL=\"$MFA_SERIAL\"" >> "$CONFIG_FILE"
    echo "DURATION=$DURATION" >> "$CONFIG_FILE"
    echo "AWS_PROFILE=\"$AWS_PROFILE\"" >> "$CONFIG_FILE"
    echo "REGION=\"$REGION\"" >> "$CONFIG_FILE"
    echo -e "\n${GREEN}配置已保存到 $CONFIG_FILE${NC}"
fi

# 清除任何现有的临时凭证环境变量
unset AWS_SESSION_TOKEN
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY

# 确保使用指定的配置文件
export AWS_PROFILE="$AWS_PROFILE"

# 检查长期凭证
echo -e "\n${YELLOW}检查AWS长期凭证...${NC}"
IDENTITY_CHECK=$(aws sts get-caller-identity --output json 2>&1)
if [ $? -ne 0 ]; then
    echo -e "${RED}警告: 长期凭证验证失败${NC}"
    
    # 检查是否是InvalidClientTokenId错误
    if [[ "$IDENTITY_CHECK" == *"InvalidClientTokenId"* ]]; then
        echo -e "${RED}错误: 长期凭证已失效${NC}"
        echo -e "\n${YELLOW}可能的原因:${NC}"
        echo "1. 访问密钥已被删除或停用"
        echo "2. 访问密钥属于不同AWS账户"
        echo "3. IAM用户被删除或停用"
        echo "4. 访问密钥已被轮换"
        
        echo -e "\n${YELLOW}是否更新长期凭证?${NC}"
        read -p "(y/n) [y]: " UPDATE_CREDS
        UPDATE_CREDS=${UPDATE_CREDS:-y}
        
        if [[ $UPDATE_CREDS =~ ^[Yy]$ ]]; then
            update_long_term_credentials
            if [ $? -ne 0 ]; then
                echo -e "${RED}凭证更新失败，无法继续${NC}"
                exit 1
            fi
        else
            echo -e "${RED}无法继续，需要有效的长期凭证${NC}"
            exit 1
        fi
    else
        echo -e "${RED}错误: $IDENTITY_CHECK${NC}"
        echo -e "\n${YELLOW}是否尝试更新长期凭证?${NC}"
        read -p "(y/n) [y]: " UPDATE_CREDS
        UPDATE_CREDS=${UPDATE_CREDS:-y}
        
        if [[ $UPDATE_CREDS =~ ^[Yy]$ ]]; then
            update_long_term_credentials
            if [ $? -ne 0 ]; then
                echo -e "${RED}凭证更新失败${NC}"
                exit 1
            fi
        else
            echo -e "${YELLOW}将尝试使用当前凭证获取临时令牌...${NC}"
        fi
    fi
else
    ACCOUNT_ID=$(echo $IDENTITY_CHECK | jq -r '.Account')
    USER_ARN=$(echo $IDENTITY_CHECK | jq -r '.Arn')
    echo -e "${GREEN}长期凭证有效!${NC}"
    echo -e "账户ID: ${YELLOW}$ACCOUNT_ID${NC}"
    echo -e "用户ARN: ${YELLOW}$USER_ARN${NC}"
    
    # 检查MFA设备ARN与账户是否匹配
    if [[ "$MFA_SERIAL" == *":mfa/"* ]]; then
        MFA_ACCOUNT=$(echo $MFA_SERIAL | cut -d':' -f5)
        if [ "$MFA_ACCOUNT" != "$ACCOUNT_ID" ]; then
            echo -e "${YELLOW}警告: MFA设备ARN中的账户ID ($MFA_ACCOUNT) 与您的账户 ($ACCOUNT_ID) 不匹配${NC}"
            echo -e "修正后的MFA设备ARN应为: ${BLUE}arn:aws:iam::${ACCOUNT_ID}:mfa/$(echo $MFA_SERIAL | cut -d'/' -f2)${NC}"
            
            read -p "是否更新MFA设备ARN? (y/n) [y]: " UPDATE_MFA
            UPDATE_MFA=${UPDATE_MFA:-y}
            if [[ $UPDATE_MFA =~ ^[Yy]$ ]]; then
                MFA_SERIAL="arn:aws:iam::${ACCOUNT_ID}:mfa/$(echo $MFA_SERIAL | cut -d'/' -f2)"
                echo -e "${GREEN}已更新MFA设备ARN为: ${BLUE}$MFA_SERIAL${NC}"
                
                # 保存更新的配置
                if [ -f "$CONFIG_FILE" ]; then
                    sed -i.bak "s|MFA_SERIAL=.*|MFA_SERIAL=\"$MFA_SERIAL\"|g" "$CONFIG_FILE" 2>/dev/null || 
                    sed -i "s|MFA_SERIAL=.*|MFA_SERIAL=\"$MFA_SERIAL\"|g" "$CONFIG_FILE"
                fi
            fi
        fi
    fi
fi

# 输入MFA代码
read -p "请输入您的6位MFA动态码: " TOKEN_CODE

# 验证MFA代码格式
until [[ $TOKEN_CODE =~ ^[0-9]{6}$ ]]; do
    echo -e "${RED}无效的MFA代码!${NC} 请输入6位数字。"
    read -p "请输入您的6位MFA动态码: " TOKEN_CODE
done

# 获取会话令牌
echo -e "\n${YELLOW}正在获取临时凭证...${NC}"
RESULT=$(aws sts get-session-token \
    --serial-number "$MFA_SERIAL" \
    --token-code "$TOKEN_CODE" \
    --duration-seconds "$DURATION" \
    --output json 2>&1)

# 检查是否有错误
if [[ $RESULT == *"error"* ]]; then
    echo -e "${RED}获取临时凭证失败:${NC}"
    echo -e "${RED}$RESULT${NC}"
    
    # 错误处理逻辑
    if [[ "$RESULT" == *"ValidationError"* && "$RESULT" == *"MultiFactorAuthentication failed"* ]]; then
        echo -e "\n${YELLOW}MFA验证失败。可能的原因:${NC}"
        echo "1. MFA代码不正确"
        echo "2. MFA设备ARN不正确"
        echo "3. MFA代码已过期（请生成新代码）"
        
        read -p "是否修改MFA设备ARN? (y/n) [n]: " MODIFY_MFA
        MODIFY_MFA=${MODIFY_MFA:-n}
        if [[ $MODIFY_MFA =~ ^[Yy]$ ]]; then
            echo -e "\n当前MFA设备ARN: ${BLUE}$MFA_SERIAL${NC}"
            read -p "新的MFA设备ARN: " NEW_MFA_SERIAL
            if [ -n "$NEW_MFA_SERIAL" ]; then
                MFA_SERIAL="$NEW_MFA_SERIAL"
                echo -e "${GREEN}已更新MFA设备ARN${NC}"
                
                # 保存更新的配置
                if [ -f "$CONFIG_FILE" ]; then
                    sed -i.bak "s|MFA_SERIAL=.*|MFA_SERIAL=\"$MFA_SERIAL\"|g" "$CONFIG_FILE" 2>/dev/null || 
                    sed -i "s|MFA_SERIAL=.*|MFA_SERIAL=\"$MFA_SERIAL\"|g" "$CONFIG_FILE"
                fi
                
                # 提示重试
                echo -e "${YELLOW}请重新运行脚本并输入新的MFA代码${NC}"
            fi
        fi
    elif [[ "$RESULT" == *"InvalidClientTokenId"* ]]; then
        echo -e "\n${RED}错误: 长期凭证已失效!${NC}"
        echo -e "请使用 --update-credentials 选项更新您的长期凭证。"
    fi
    
    exit 1
fi

# 提取临时凭证
ACCESS_KEY=$(echo $RESULT | jq -r '.Credentials.AccessKeyId')
SECRET_KEY=$(echo $RESULT | jq -r '.Credentials.SecretAccessKey')
SESSION_TOKEN=$(echo $RESULT | jq -r '.Credentials.SessionToken')
EXPIRATION=$(echo $RESULT | jq -r '.Credentials.Expiration')

# 设置临时凭证环境变量
export AWS_ACCESS_KEY_ID=$ACCESS_KEY
export AWS_SECRET_ACCESS_KEY=$SECRET_KEY
export AWS_SESSION_TOKEN=$SESSION_TOKEN
export AWS_PROFILE="$AWS_PROFILE"
export AWS_REGION="$REGION"

# 更新AWS配置文件
aws configure set aws_access_key_id "$ACCESS_KEY" --profile "$AWS_PROFILE"
aws configure set aws_secret_access_key "$SECRET_KEY" --profile "$AWS_PROFILE"
aws configure set aws_session_token "$SESSION_TOKEN" --profile "$AWS_PROFILE"
aws configure set region "$REGION" --profile "$AWS_PROFILE"

# 验证临时凭证
echo -e "\n${YELLOW}验证临时凭证...${NC}"
IDENTITY=$(aws sts get-caller-identity --output json 2>&1)

if [[ $IDENTITY == *"error"* ]]; then
    echo -e "${RED}凭证验证失败:${NC}"
    echo -e "${RED}$IDENTITY${NC}"
    exit 1
else
    USER_ARN=$(echo $IDENTITY | jq -r '.Arn')
    ACCOUNT_ID=$(echo $IDENTITY | jq -r '.Account')
    
    echo -e "${GREEN}临时凭证设置成功!${NC}"
    echo -e "账户ID: ${YELLOW}$ACCOUNT_ID${NC}"
    echo -e "用户ARN: ${YELLOW}$USER_ARN${NC}"
    echo -e "过期时间: ${YELLOW}$EXPIRATION${NC}"
    
    # 尝试列出S3存储桶作为进一步验证
    echo -e "\n${YELLOW}验证S3权限...${NC}"
    aws s3 ls &> /dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}S3访问权限验证成功!${NC}"
        
        # 显示存储桶列表
        BUCKETS=$(aws s3 ls)
        if [ -n "$BUCKETS" ]; then
            echo -e "${YELLOW}存储桶列表:${NC}"
            echo "$BUCKETS"
        else
            echo -e "${YELLOW}账户中没有S3存储桶。${NC}"
        fi
    else
        echo -e "${YELLOW}注意: 无法列出S3存储桶。这可能是正常的，取决于您的权限。${NC}"
    fi
    
    # 创建命令以供复制
    echo -e "\n${BLUE}=============== 临时凭证环境变量 ===============${NC}"
    echo -e "export AWS_ACCESS_KEY_ID=$ACCESS_KEY"
    echo -e "export AWS_SECRET_ACCESS_KEY=$SECRET_KEY"
    echo -e "export AWS_SESSION_TOKEN=$SESSION_TOKEN"
    echo -e "export AWS_REGION=$REGION"
    echo -e "export AWS_PROFILE=$AWS_PROFILE"
    echo -e "${BLUE}=================================================${NC}"
    
    # 计算凭证过期时间
    EXPIRY_DATE=$(date -d "$EXPIRATION" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S+00:00" "$EXPIRATION" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    if [ -z "$EXPIRY_DATE" ]; then
        EXPIRY_DATE=$EXPIRATION  # 使用原始格式
    fi
    
    echo -e "\n${GREEN}凭证已自动配置到当前会话和AWS配置文件中。${NC}"
    echo -e "您可以复制上述环境变量到其他终端窗口以共享这些凭证。"
    echo -e "临时凭证有效期至: ${YELLOW}$EXPIRY_DATE${NC}"
    
    # 计算剩余时间（如果可能）
    NOW=$(date +%s)
    EXPIRY_SECONDS=$(date -d "$EXPIRATION" +%s 2>/dev/null)
    if [ -n "$EXPIRY_SECONDS" ]; then
        REMAINING=$((EXPIRY_SECONDS - NOW))
        REMAINING_HOURS=$((REMAINING / 3600))
        REMAINING_MINUTES=$(( (REMAINING % 3600) / 60 ))
        echo -e "剩余时间: ${YELLOW}${REMAINING_HOURS}小时${REMAINING_MINUTES}分钟${NC}"
    fi
fi

# 提示设置别名
echo -e "\n${BLUE}提示:${NC}"
echo -e "您可以在shell配置文件中添加以下别名，方便调用此脚本:"
echo -e "${YELLOW}alias aws-mfa='$(readlink -f $0)'${NC}"
