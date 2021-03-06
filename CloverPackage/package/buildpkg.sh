#!/bin/bash

# old=1755= ${SRCROOT}/package/buildpkg.sh ${SYMROOT}/package;
# new=1756=@${SRCROOT}/package/buildpkg.sh "$(SRCROOT)" "$(SYMROOT)" "$(PKG_BUILD_DIR)"

# 1=SRCROOT = $(CURDIR)
# 2=SYMROOT = $(SRCROOT)/sym
# 3=PKG_BUILD_DIR = $(SYMROOT)/package

# $3 Path to store built package

# Prevent the script from doing bad things
set -u  # Abort with unset variables

packagename="Clover"

declare -r PKGROOT="${0%/*}"    # ie. edk2/Clover/CloverPackage/package
declare -r SRCROOT="${1}"       # ie. edk2/Clover/CloverPackage
declare -r SYMROOT="${2}"       # ie. edk2/Clover/CloverPackage/sym
declare -r PKG_BUILD_DIR="${3}" # ie. edk2/Clover/CloverPackage/sym/package
declare -r SCPT_TPL_DIR="${PKGROOT}/Scripts.templates"
declare -r SCPT_LIB_DIR="${PKGROOT}/Scripts.libraries"

if [[ $# -lt 3 ]];then
    echo "Too few arguments. Aborting..." >&2 && exit 1
fi

if [[ ! -d "$SYMROOT" ]];then
    echo "Directory ${SYMROOT} doesn't exit. Aborting..." >&2 && exit 1
fi

# ====== LANGUAGE SETUP ======
export LANG='en_US.UTF-8'
export LC_COLLATE='C'
export LC_CTYPE='C'

# ====== COLORS ======
COL_BLACK="\x1b[30;01m"
COL_RED="\x1b[31;01m"
COL_GREEN="\x1b[32;01m"
COL_YELLOW="\x1b[33;01m"
COL_MAGENTA="\x1b[35;01m"
COL_CYAN="\x1b[36;01m"
COL_WHITE="\x1b[37;01m"
COL_BLUE="\x1b[34;01m"
COL_RESET="\x1b[39;49;00m"

# ====== REVISION/VERSION ======
declare -r CLOVER_VERSION=$( cat version )
# stage
CLOVER_STAGE=${CLOVER_VERSION##*-}
CLOVER_STAGE=${CLOVER_STAGE/RC/Release Candidate }
CLOVER_STAGE=${CLOVER_STAGE/FINAL/2.2 Final}
declare -r CLOVER_STAGE
declare -r CLOVER_REVISION=$( cat revision )
declare -r CLOVER_BUILDDATE=$( sed -n 's/.*FIRMWARE_BUILDDATE *\"\(.*\)\".*/\1/p' "${PKGROOT}/../../Version.h" )
declare -r CLOVER_TIMESTAMP=$( date -j -f "%Y-%m-%d %H:%M:%S" "${CLOVER_BUILDDATE}" "+%s" )

# =================
declare -r CLOVER_DEVELOP=$(awk "NR==6{print;exit}"  ${PKGROOT}/../CREDITS)
declare -r CLOVER_CREDITS=$(awk "NR==10{print;exit}" ${PKGROOT}/../CREDITS)
declare -r CLOVER_PKGDEV=$(awk "NR==14{print;exit}"  ${PKGROOT}/../CREDITS)
declare -r CLOVER_CPRYEAR=$(awk "NR==18{print;exit}" ${PKGROOT}/../CREDITS)
whoami=$(whoami | awk '{print $1}' | cut -d ":" -f3)
if [[ "$whoami" == "admin" ]];then
    declare -r CLOVER_WHOBUILD="VoodooLabs BuildBot"
else
    declare -r CLOVER_WHOBUILD="$whoami"
fi

# ====== GLOBAL VARIABLES ======
declare -r LOG_FILENAME="Clover_Installer_Log.txt"
declare -r CLOVER_INSTALLER_PLIST="/Library/Preferences/com.projectosx.clover.installer.plist"

declare -a pkgrefs
declare -a choice_key
declare -a choice_options
declare -a choice_selected
declare -a choice_force_selected
declare -a choice_title
declare -a choive_description
declare -a choice_pkgrefs
declare -a choice_parent_group_index
declare -a choice_group_items
declare -a choice_group_exclusive

# Init Main Group
choice_key[0]=""
choice_options[0]=""
choice_title[0]=""
choice_description[0]=""
choices_pkgrefs[0]=""
choice_group_items[0]=""
choice_group_exclusive[0]=""

# =================

# Package identifiers
declare -r clover_package_identity="org.clover"

# ====== FUNCTIONS ======
trim () {
    local result="${1#"${1%%[![:space:]]*}"}"   # remove leading whitespace characters
    echo "${result%"${result##*[![:space:]]}"}" # remove trailing whitespace characters
}

# Check if an element is in an array
# Arguments:
#    $1: string to search
#    $2+: array elements
#
# Return the string if found else return an empty string
function inArray() {
  local element
  for element in "${@:2}"; do [[ "$element" == "$1" ]] && echo "$element" && return 0; done
  return 1
}

function makeSubstitutions () {
    # Substition is like: Key=Value
    #
    # Optional arguments:
    #    --subst=<substition> : add a new substitution
    #
    # Last argument(s) is/are file(s) where substitutions must be made

    local ownSubst=""

    function addSubst () {
        local mySubst="$1"
        case "$mySubst" in
            *=*) keySubst=${mySubst%%=*}
                 valSubst=${mySubst#*=}
                 ownSubst=$(printf "%s\n%s" "$ownSubst" "s&@$keySubst@&$valSubst&g;t t")
                 ;;
            *) echo "Invalid substitution $mySubst" >&2
               exit 1
               ;;
        esac
    }

    # Check the arguments.
    while [[ $# -gt 0 ]];do
        local option="$1"
        case "$option" in
            --subst=*) shift; addSubst "${option#*=}" ;;
            -*)
                echo "Unrecognized makeSubstitutions option '$option'" >&2
                exit 1
                ;;
            *)  break ;;
        esac
    done

    if [[ $# -lt 1 ]];then
        echo "makeSubstitutions invalid number of arguments: at least one file needed" >&2
        exit 1
    fi

    local cloverSubsts="
s&%CLOVERVERSION%&${CLOVER_VERSION%%-*}&g
s&%CLOVERREVISION%&${CLOVER_REVISION}&g
s&%CLOVERSTAGE%&${CLOVER_STAGE}&g
s&%DEVELOP%&${CLOVER_DEVELOP}&g
s&%CREDITS%&${CLOVER_CREDITS}&g
s&%PKGDEV%&${CLOVER_PKGDEV}&g
s&%CPRYEAR%&${CLOVER_CPRYEAR}&g
s&%WHOBUILD%&${CLOVER_WHOBUILD}&g
:t
/@[a-zA-Z_][a-zA-Z_0-9]*@/!b
s&@CLOVER_INSTALLER_PLIST_NEW@&${CLOVER_INSTALLER_PLIST}.new&g
s&@CLOVER_INSTALLER_PLIST@&${CLOVER_INSTALLER_PLIST}&g
s&@LOG_FILENAME@&${LOG_FILENAME}&g;t t"

    local allSubst="
$cloverSubsts
$ownSubst"

    for file in "$@";do
        cp -pf "$file" "${file}.in"
        sed "$allSubst" "${file}.in" > "${file}"
        rm -f "${file}.in"
    done
}


addTemplateScripts () {
    # Arguments:
    #    --pkg-rootdir=<pkg_rootdir> : path of the pkg root dir
    #
    # Optional arguments:
    #    --subst=<substition> : add a new substitution
    #
    # Substition is like: Key=Value
    #
    # $n : Name of template(s) (templates are in package/Scripts.templates

    local pkgRootDir=""
    declare -a allSubst

    # Check the arguments.
    while [[ $# -gt 0 ]];do
        local option="$1"
        case "$option" in
            --pkg-rootdir=*)   shift; pkgRootDir="${option#*=}" ;;
            --subst=*) shift; allSubst[${#allSubst[*]}]="${option}" ;;
            -*)
                echo "Unrecognized addTemplateScripts option '$option'" >&2
                exit 1
                ;;
            *)  break ;;
        esac
    done
    if [[ $# -lt 1 ]];then
        echo "addTemplateScripts invalid number of arguments: you must specify a template name" >&2
        exit 1
    fi
    [[ -z "$pkgRootDir" ]] && { echo "Error addTemplateScripts: --pkg-rootdir option is needed" >&2 ; exit 1; }
    [[ ! -d "$pkgRootDir" ]] && { echo "Error addTemplateScripts: directory '$pkgRootDir' doesn't exists" >&2 ; exit 1; }

    for templateName in "$@";do
        local templateRootDir="${SCPT_TPL_DIR}/${templateName}"
        [[ ! -d "$templateRootDir" ]] && {
            echo "Error addTemplateScripts: template '$templateName' doesn't exists" >&2; exit 1; }

        # Copy files to destination
        rsync -pr --exclude=.svn --exclude="*~" "$templateRootDir/" "$pkgRootDir/Scripts/"
    done

    files=$( find "$pkgRootDir/Scripts/" -type f )
    if [[ ${#allSubst[*]} -gt 0 ]];then
        makeSubstitutions "${allSubst[@]}" $files
    else
        makeSubstitutions $files
    fi
}

getPackageRefId () {
    echo ${1//_/.}.${2//_/.} | tr [:upper:] [:lower:]
}

# Return index of a choice
getChoiceIndex () {
    # $1 Choice Id
    local found=0
    for (( idx=0 ; idx < ${#choice_key[*]}; idx++ ));do
        if [[ "${1}" == "${choice_key[$idx]}" ]];then
            found=1
            break
        fi
    done
    echo "$idx"
    return $found
}

# Add a new choice
addChoice () {
    # Optional arguments:
    #    --title=<title> : Force the title
    #    --description=<description> : Force the description
    #    --group=<group> : Group Choice Id
    #    --start-selected=<javascript code> : Specifies whether this choice is initially selected or unselected
    #    --start-enabled=<javascript code>  : Specifies the initial enabled state of this choice
    #    --start-visible=<javascript code>  : Specifies whether this choice is initially visible
    #    --pkg-refs=<pkgrefs> : List of package reference(s) id (separate by spaces)
    #
    # $1 Choice Id

    local option
    local title=""
    local description=""
    local groupChoice=""
    local choiceOptions=""
    local choiceSelected=""
    local choiceForceSelected=""
    local pkgrefs=""

    # Check the arguments.
    for option in "${@}";do
        case "$option" in
            --title=*)
                       shift; title="${option#*=}" ;;
            --description=*)
                       shift; description="${option#*=}" ;;
            --group=*)
                       shift; groupChoice=${option#*=} ;;
            --start-selected=*)
                       shift; choiceOptions="$choiceOptions start_selected=\"${option#*=}\"" ;;
            --start-enabled=*)
                       shift; choiceOptions="$choiceOptions start_enabled=\"${option#*=}\"" ;;
            --start-visible=*)
                       shift; choiceOptions="$choiceOptions start_visible=\"${option#*=}\"" ;;
            --enabled=*)
                       shift; choiceOptions="$choiceOptions enabled=\"${option#*=}\"" ;;
            --selected=*)
                       shift; choiceSelected="${option#*=}" ;;
            --force-selected=*)
                       shift; choiceForceSelected="${option#*=}" ;;
            --visible=*)
                       shift; choiceOptions="$choiceOptions visible=\"${option#*=}\"" ;;
            --pkg-refs=*)
                       shift; pkgrefs=${option#*=} ;;
            -*)
                echo "Unrecognized addChoice option '$option'" >&2
                exit 1
                ;;
            *)  break ;;
        esac
    done

    if [[ $# -ne 1 ]];then
        echo "addChoice invalid number of arguments: ${@}" >&2
        exit 1
    fi

    local choiceId="${1}"

    # Add choice in the group
    idx_group=$(getChoiceIndex "$groupChoice")
    found_group=$?
    if [[ $found_group -ne 1 ]];then
        # No group exist
        echo "Error can't add choice '$choiceId' to group '$groupChoice': group choice '$groupChoice' doesn't exists." >&2
        exit 1
    else
        set +u; oldItems=${choice_group_items[$idx_group]}; set -u
        choice_group_items[$idx_group]="$oldItems $choiceId"
    fi

    # Check that the choice doesn't already exists
    idx=$(getChoiceIndex "$choiceId")
    found=$?
    if [[ $found -ne 0 ]];then
        # Choice already exists
        echo "Error can't add choice '$choiceId': a choice with same name already exists." >&2
        exit 1
    fi

    # Record new node
    choice_key[$idx]="$choiceId"
    choice_title[$idx]="${title:-${choiceId}_title}"
    choice_description[$idx]="${description:-${choiceId}_description}"
    choice_options[$idx]=$(trim "${choiceOptions}") # Removing leading and trailing whitespace(s)
    choice_selected[$idx]=$(trim "${choiceSelected}") # Removing leading and trailing whitespace(s)
    choice_force_selected[$idx]=$(trim "${choiceForceSelected}") # Removing leading and trailing whitespace(s)
    choice_parent_group_index[$idx]=$idx_group
    choice_pkgrefs[$idx]="$pkgrefs"

    return $idx
}

# Add a group choice
addGroupChoices() {
    # Optional arguments:
    #    --title=<title> : Force the title
    #    --description=<description> : Force the description
    #    --parent=<parent> : parent group choice id
    #    --exclusive_zero_or_one_choice : only zero or one choice can be selected in the group
    #    --exclusive_one_choice : only one choice can be selected in the group
    #
    # $1 Choice Id

    local option
    local title=""
    local description=""
    local groupChoice=""
    local exclusive_function=""
    local choiceOptions=

    for option in "${@}";do
        case "$option" in
            --title=*)
                       shift; title="${option#*=}" ;;
            --description=*)
                       shift; description="${option#*=}" ;;
            --exclusive_zero_or_one_choice)
                       shift; exclusive_function="exclusive_zero_or_one_choice" ;;
            --exclusive_one_choice)
                       shift; exclusive_function="exclusive_one_choice" ;;
            --parent=*)
                       shift; groupChoice=${option#*=} ;;
            --start-selected=*)
                       shift; choiceOptions+=("--start-selected=${option#*=}") ;;
            --start-enabled=*)
                       shift; choiceOptions+=("--start-enabled=${option#*=}") ;;
            --start-visible=*)
                       shift; choiceOptions+=("--start-visible=${option#*=}") ;;
            --enabled=*)
                       shift; choiceOptions+=("--enabled=${option#*=}") ;;
            --selected=*)
                       shift; choiceOptions+=("--selected=${option#*=}") ;;
           -*)
                echo "Unrecognized addGroupChoices option '$option'" >&2
                exit 1
                ;;
            *)  break ;;
        esac
    done

    if [[ $# -ne 1 ]];then
        echo "addGroupChoices invalid number of arguments: ${@}" >&2
        exit 1
    fi

    addChoice --group="$groupChoice" --title="$title" --description="$description" ${choiceOptions[*]} "${1}"
    local idx=$? # index of the new created choice

    choice_group_exclusive[$idx]="$exclusive_function"
}

exclusive_one_choice () {
    # $1 Current choice (ie: test1)
    # $2..$n Others choice(s) (ie: "test2" "test3"). Current can or can't be in the others choices
    local myChoice="${1}"
    local result="";
    local separator=' || ';
    for choice in ${@:2};do
        if [[ "$choice" != "$myChoice" ]];then
            result="${result}choices['$choice'].selected${separator}";
        fi
    done
    if [[ -n "$result" ]];then
        echo "!(${result%$separator})"
    else
        echo "choices['$myChoice'].selected"
    fi
}

exclusive_zero_or_one_choice () {
    # $1 Current choice (ie: test1)
    # $2..$n Others choice(s) (ie: "test2" "test3"). Current can or can't be in the others choices
    local myChoice="${1}"
    local result;
    local exclusive_one_choice_code="$(exclusive_one_choice ${@})"
    echo "(my.choice.selected &amp;&amp; $(exclusive_one_choice ${@}))"
}

main ()
{

# clean up the destination path

    rm -R -f "${PKG_BUILD_DIR}"
    echo ""
    echo -e $COL_CYAN"  ----------------------------------"$COL_RESET
    echo -e $COL_CYAN"  Building $packagename Install Package"$COL_RESET
    echo -e $COL_CYAN"  ----------------------------------"$COL_RESET
    echo ""

# build Pre package
    echo "====================== Preinstall ======================"
    packagesidentity="${clover_package_identity}"
    choiceId="Pre"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}" ${choiceId}
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    addChoice --start-visible="false"  --start-selected="true"  --pkg-refs="$packageRefId" "${choiceId}"
# End pre install choice

# Check if we have compile IA32 version
    local add_ia32=0
    ls "${SRCROOT}"/CloverV2/Bootloaders/ia32/boot? &>/dev/null && add_ia32=1

# build UEFI only
    echo "===================== Installation ====================="
    packagesidentity="$clover_package_identity"
    choiceId="UEFI.only"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root/EFI
    rsync -r --exclude=.svn --exclude="*~" --exclude='drivers*'   \
     ${SRCROOT}/CloverV2/EFI/BOOT ${PKG_BUILD_DIR}/${choiceId}/Root/EFI/
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}" \
                       --subst="INSTALLER_CHOICE=$packageRefId" MarkChoice
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/EFIROOTDIR"
    addChoice --start-visible="true" --start-selected="choicePreviouslySelected('$packageRefId')"  \
              --pkg-refs="$packageRefId" "${choiceId}"
# End UEFI only

# build EFI target
    echo "================== Target ESP =========================="
    packagesidentity="$clover_package_identity"
    choiceId="Target.ESP"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    installer_target_esp_refid=$packageRefId
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}" \
                       --subst="INSTALLER_CHOICE=$installer_target_esp_refid" MarkChoice
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    addChoice --start-visible="true" --start-selected="choicePreviouslySelected('$packageRefId')"  \
              --selected="choices['UEFI.only'].selected || choices['Target.ESP'].selected"         \
              --pkg-refs="$packageRefId" "${choiceId}"
# End build EFI target

# build BiosBoot package
    echo "=================== BiosBoot ==========================="
    packagesidentity="$clover_package_identity"
    choiceId="BiosBoot"

    if [[ "$add_ia32" -eq 1 ]]; then
        ditto --noextattr --noqtn ${SRCROOT}/CloverV2/Bootloaders/ia32/boot? ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/ia32/
    fi
    ls "${SRCROOT}"/CloverV2/Bootloaders/x64/boot? &>/dev/null && \
     ditto --noextattr --noqtn ${SRCROOT}/CloverV2/Bootloaders/x64/boot?  ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/x64/
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/boot0af     ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/boot0ss     ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/boot1f32    ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/boot1f32alt ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/boot1h      ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/boot1h2     ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/boot1x      ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/boot1xalt   ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/

    ditto --noextattr --noqtn ${SRCROOT}/utils/fdisk440/fdisk440.8        ${PKG_BUILD_DIR}/${choiceId}/Root/usr/local/man/man8/
    ditto --noextattr --noqtn ${SYMROOT}/utils/fdisk440                   ${PKG_BUILD_DIR}/${choiceId}/Root/usr/local/bin/
    ditto --noextattr --noqtn ${SYMROOT}/utils/boot1-install              ${PKG_BUILD_DIR}/${choiceId}/Root/usr/local/bin/

    # Add some documentation
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/Description.txt  ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/Installation.txt ${PKG_BUILD_DIR}/${choiceId}/Root/usr/standalone/i386/
    ditto --noextattr --noqtn ${SRCROOT}/CloverV2/BootSectors/Installation.txt ${PKG_BUILD_DIR}/${choiceId}/Root/EFIROOTDIR/EFI/CLOVER/doc/

    fixperms "${PKG_BUILD_DIR}/${choiceId}/Root/"
    chmod 755 "${PKG_BUILD_DIR}/${choiceId}"/Root/usr/local/bin/{fdisk440,boot1-install}

    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    packageBiosBootRefId=$packageRefId
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    addChoice --start-visible="false" --start-selected="false" --pkg-refs="$packageRefId" "${choiceId}"
# End build BiosBoot package

# build Utils package
    echo "===================== Utils ============================"
    packagesidentity="$clover_package_identity"
    choiceId="Utils"
    # Utils
    ditto --noextattr --noqtn ${SYMROOT}/utils/bdmesg            ${PKG_BUILD_DIR}/${choiceId}/Root/usr/local/bin/
    ditto --noextattr --noqtn ${SYMROOT}/utils/clover-genconfig  ${PKG_BUILD_DIR}/${choiceId}/Root/usr/local/bin/
    ditto --noextattr --noqtn ${SYMROOT}/utils/partutil          ${PKG_BUILD_DIR}/${choiceId}/Root/usr/local/bin/
    fixperms "${PKG_BUILD_DIR}/${choiceId}/Root/"
    chmod 755 "${PKG_BUILD_DIR}/${choiceId}"/Root/usr/local/bin/{bdmesg,clover-genconfig,partutil}
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    packageUtilsRefId=$packageRefId
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    addChoice --start-visible="false" --start-selected="true"  \
              --pkg-refs="$packageRefId" "${choiceId}"
# End build Utils package

# build core EFI folder package
    echo "===================== EFI folder ======================="
    packagesidentity="$clover_package_identity"
    choiceId="EFIFolder"
    rm -rf   ${PKG_BUILD_DIR}/${choiceId}/Root/EFI
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root/EFI
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Scripts
    # Add the partutil binary as a helper to mount ESP
    ditto --noextattr --noqtn ${SYMROOT}/utils/partutil  ${PKG_BUILD_DIR}/${choiceId}/Scripts/
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}"                     \
                       --subst="CLOVER_PACKAGE_IDENTITY=$clover_package_identity"       \
                       --subst="INSTALLER_TARGET_ESP_REFID=$installer_target_esp_refid" \
                       ${choiceId}
    rsync -r --exclude=.svn --exclude="*~" --exclude='drivers*'   \
     ${SRCROOT}/CloverV2/EFI/BOOT ${PKG_BUILD_DIR}/${choiceId}/Root/EFI/
    rsync -r --exclude=.svn --exclude="*~" --exclude='drivers*'   \
     ${SRCROOT}/CloverV2/EFI/CLOVER ${PKG_BUILD_DIR}/${choiceId}/Root/EFI/
    [[ "$add_ia32" -ne 1 ]] && rm -rf ${PKG_BUILD_DIR}/${choiceId}/Root/EFI/drivers32
    # config.plist
    rm -f ${PKG_BUILD_DIR}/${choiceId}/Root/EFI/CLOVER/config.plist &>/dev/null
    fixperms "${PKG_BUILD_DIR}/${choiceId}/Root/"

    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/EFIROOTDIR"
    addChoice --start-visible="false" --start-selected="true" --pkg-refs="$packageRefId" "${choiceId}"
# End build EFI folder package

# Create Bootloader Node
    addGroupChoices --enabled="!choices['UEFI.only'].selected" --exclusive_one_choice "Bootloader"
    echo "===================== BootLoaders ======================"
    packagesidentity="$clover_package_identity".bootloader

# build alternative booting package
    choiceId="AltBoot"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    altbootRefId=$packageRefId
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root

    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}" \
                       --subst="INSTALLER_CHOICE=$packageRefId"     \
                       MarkChoice
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}"  ${choiceId}

    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/EFIROOTDIR"
    addChoice --start-selected="choicePreviouslySelected('$packageRefId')"                          \
              --selected="!choices['UEFI.only'].selected &amp;&amp; choices['$choiceId'].selected"  \
              --visible="choices['boot0af'].selected || choices['boot0ss'].selected"                \
              --pkg-refs="$packageBiosBootRefId $packageUtilsRefId $packageRefId" "${choiceId}"
# End alternative booting package

# build bootNo package
    choiceId="bootNo"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}"     \
                       --subst="INSTALLER_CHOICE=$packageRefId"         \
                       --subst="INSTALLER_ALTBOOT_REFID=$altbootRefId"  \
                       ${choiceId}
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/EFIROOTDIR"
    addChoice --group="Bootloader"                                                                \
              --enabled="!choices['UEFI.only'].selected"                                          \
              --start-selected="choicePreviouslySelected('$packageRefId') || checkBootFromUEFI()" \
              --force-selected="choices['UEFI.only'].selected"                                    \
              --pkg-refs="$packageRefId" "${choiceId}"
# End build bootNo package

# build boot0af package
    choiceId="boot0af"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}"     \
                       --subst="INSTALLER_CHOICE=$packageRefId"         \
                       --subst="INSTALLER_ALTBOOT_REFID=$altbootRefId"  \
                       --subst="MBR_SECTOR_FILE"=boot0af                \
                       InstallBootsectors
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/EFIROOTDIR"
    addChoice --group="Bootloader"                                         \
              --enabled="!choices['UEFI.only'].selected"                   \
              --start-selected="choicePreviouslySelected('$packageRefId')" \
              --pkg-refs="$packageBiosBootRefId $packageUtilsRefId $packageRefId" "${choiceId}"
# End build boot0af package

# build boot0ss package
    choiceId="boot0ss"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}"     \
                       --subst="INSTALLER_CHOICE=$packageRefId"         \
                       --subst="INSTALLER_ALTBOOT_REFID=$altbootRefId"  \
                       --subst="MBR_SECTOR_FILE"=boot0ss                \
                       InstallBootsectors
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/EFIROOTDIR"
    addChoice --group="Bootloader"                                          \
              --enabled="!choices['UEFI.only'].selected"                    \
              --start-selected="choicePreviouslySelected('$packageRefId')"  \
              --pkg-refs="$packageBiosBootRefId $packageUtilsRefId $packageRefId" "${choiceId}"
# End build boot0ss package

# Create CloverEFI Node
    echo "====================== CloverEFI ======================="
    nb_cloverEFI=$(find "${SRCROOT}"/CloverV2/Bootloaders -type f -name 'boot?' | wc -l)
    local cloverEFIGroupOption=(--exclusive_one_choice)
    [[ "$nb_cloverEFI" -lt 2 ]] && cloverEFIGroupOption=(--selected="!choices['UEFI.only'].selected")
    addGroupChoices --enabled="!choices['UEFI.only'].selected" ${cloverEFIGroupOption[@]} "CloverEFI"

# build cloverEFI.32 package
if [[ -f "${SRCROOT}/CloverV2/Bootloaders/ia32/boot3" ]]; then
    packagesidentity="$clover_package_identity"
    choiceId="cloverEFI.32"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}"  \
                       --subst="CLOVER_EFI_ARCH=ia32"                \
                       --subst="CLOVER_BOOT_FILE=boot3"              \
                       --subst="INSTALLER_CHOICE=$packageRefId"      \
                       CloverEFI
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    local choiceOptions=(--group="CloverEFI" --enabled="!choices['UEFI.only'].selected")
    [[ "$nb_cloverEFI" -ge 2 ]] && \
     choiceOptions+=(--start-selected="choicePreviouslySelected('$packageRefId')")
    choiceOptions+=(--selected="!choices['UEFI.only'].selected")
    addChoice ${choiceOptions[@]} --pkg-refs="$packageBiosBootRefId $packageRefId" "${choiceId}"
fi
# End build cloverEFI.32 package

# build cloverEFI.64.sata package
if [[ -f "${SRCROOT}/CloverV2/Bootloaders/x64/boot6" ]]; then
    packagesidentity="$clover_package_identity"
    choiceId="cloverEFI.64.sata"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}"  \
                       --subst="CLOVER_EFI_ARCH=x64"                 \
                       --subst="CLOVER_BOOT_FILE=boot6"              \
                       --subst="INSTALLER_CHOICE=$packageRefId"      \
                       CloverEFI
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    local choiceOptions=(--group="CloverEFI" --enabled="!choices['UEFI.only'].selected")
    [[ "$nb_cloverEFI" -ge 2 ]] && \
     choiceOptions+=(--start-selected="choicePreviouslySelected('$packageRefId')")
    choiceOptions+=(--selected="!choices['UEFI.only'].selected")
    addChoice ${choiceOptions[@]} --pkg-refs="$packageBiosBootRefId $packageRefId" "${choiceId}"
fi
# End build boot64 package

# build cloverEFI.64.blockio package
if [[ -f "${SRCROOT}/CloverV2/Bootloaders/x64/boot7" ]]; then
    packagesidentity="$clover_package_identity"
    choiceId="cloverEFI.64.blockio"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}"  \
                       --subst="CLOVER_EFI_ARCH=x64"                 \
                       --subst="CLOVER_BOOT_FILE=boot7"              \
                       --subst="INSTALLER_CHOICE=$packageRefId"      \
                       CloverEFI
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    local choiceOptions=(--group="CloverEFI" --enabled="!choices['UEFI.only'].selected")
    [[ "$nb_cloverEFI" -ge 2 ]] && \
     choiceOptions+=(--start-selected="choicePreviouslySelected('$packageRefId')")
    choiceOptions+=(--selected="!choices['UEFI.only'].selected")
    addChoice ${choiceOptions[@]} --pkg-refs="$packageBiosBootRefId $packageRefId" "${choiceId}"
fi
# End build cloverEFI.64.blockio package

# build theme packages
    echo "======================== Themes ========================"
    addGroupChoices "Themes"
    local specialThemes=('christmas' 'newyear')

    # Using themes section from Azi's/package branch.
    packagesidentity="${clover_package_identity}".themes
    local artwork="${SRCROOT}/CloverV2/themespkg/"
    local themes=($( find "${artwork}" -type d -depth 1 -not -name '.svn' ))
    local themeDestDir='/EFIROOTDIR/EFI/CLOVER/themes'
    local defaultTheme=  # $(trim $(sed -n 's/^theme *//p' "${SRCROOT}"/CloverV2/EFI/CLOVER/refit.conf))
    for (( i = 0 ; i < ${#themes[@]} ; i++ )); do
        local themeName=${themes[$i]##*/}
        [[ -n $(inArray "$themeName" ${specialThemes[@]}) ]] && continue # it is a special theme
        mkdir -p "${PKG_BUILD_DIR}/${themeName}/Root/"
        rsync -r --exclude=.svn --exclude="*~" "${themes[$i]}/" "${PKG_BUILD_DIR}/${themeName}/Root/${themeName}"
        packageRefId=$(getPackageRefId "${packagesidentity}" "${themeName}")
        addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${themeName}" \
                           --subst="themeName=$themeName"                \
                           --subst="INSTALLER_CHOICE=$packageRefId"      \
                           InstallTheme

        buildpackage "$packageRefId" "${themeName}" "${PKG_BUILD_DIR}/${themeName}" "${themeDestDir}"

        # local selectTheme="checkFileExists('${themeDestDir}/$themeName/icons/func_clover.png')"
        local selectTheme="choicePreviouslySelected('$packageRefId')"
        # Select the default theme
        [[ "$themeName" == "$defaultTheme" ]] && selectTheme='true'
        addChoice --group="Themes"  --start-selected="$selectTheme"  --pkg-refs="$packageRefId"  "${themeName}"
    done

    # Special themes
    packagesidentity="${clover_package_identity}".special.themes
    local artwork="${SRCROOT}/CloverV2/themespkg/"
    local themeDestDir='/EFIROOTDIR/EFI/CLOVER/themes'
    local currentMonth=$(date -j +'%-m')
    for (( i = 0 ; i < ${#specialThemes[@]} ; i++ )); do
        local themeName=${specialThemes[$i]##*/}
        # Don't add christmas and newyear themes if month < 11
        [[ $currentMonth -lt 11 ]] && [[ "$themeName" == christmas || "$themeName" == newyear ]] && continue
        mkdir -p "${PKG_BUILD_DIR}/${themeName}/Root/"
        rsync -r --exclude=.svn --exclude="*~" "$artwork/${specialThemes[$i]}/" "${PKG_BUILD_DIR}/${themeName}/Root/${themeName}"
        packageRefId=$(getPackageRefId "${packagesidentity}" "${themeName}")
        addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${themeName}" \
                           --subst="themeName=$themeName"                \
                           --subst="INSTALLER_CHOICE=$packageRefId"      \
                           InstallTheme

        buildpackage "$packageRefId" "${themeName}" "${PKG_BUILD_DIR}/${themeName}" "${themeDestDir}"
        addChoice --start-visible="false"  --start-selected="true"  --pkg-refs="$packageRefId" "${themeName}"
    done
# End build theme packages
 
if [[ "$add_ia32" -eq 1 ]]; then
# build mandatory drivers-ia32 packages
    echo "================= drivers32 mandatory =================="
    packagesidentity="${clover_package_identity}".drivers32.mandatory
    local drivers=($( find "${SRCROOT}/CloverV2/EFI/CLOVER/drivers32" -type f -name '*.efi' -depth 1 ))
    local driverDestDir='/EFIROOTDIR/EFI/CLOVER/drivers32'
    for (( i = 0 ; i < ${#drivers[@]} ; i++ ))
    do
        local driver="${drivers[$i]##*/}"
        local driverChoice="${driver%.efi}"
        ditto --noextattr --noqtn --arch i386 "${drivers[$i]}" "${PKG_BUILD_DIR}/${driverChoice}/Root/"
        find "${PKG_BUILD_DIR}/${driverChoice}" -name '.DS_Store' -exec rm -R -f {} \; 2>/dev/null
        fixperms "${PKG_BUILD_DIR}/${driverChoice}/Root/"

        packageRefId=$(getPackageRefId "${packagesidentity}" "${driverChoice}")
        # Add postinstall script for VBoxHfs driver to remove it if HFSPlus driver exists
        [[ "$driver" == VBoxHfs* ]] && \
         addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${driverChoice}"  \
                            --subst="DRIVER_NAME=$driver"                     \
                            --subst="DRIVER_DIR=$(basename $driverDestDir)"   \
                            "VBoxHfs"
        buildpackage "$packageRefId" "${driverChoice}" "${PKG_BUILD_DIR}/${driverChoice}" "${driverDestDir}"
        addChoice --start-visible="false" --selected="!choices['UEFI.only'].selected"  \
         --pkg-refs="$packageRefId"  "${driverChoice}"
        rm -R -f "${PKG_BUILD_DIR}/${driverChoice}"
    done
# End mandatory drivers-ia32 packages

# build drivers-ia32 packages
    echo "===================== drivers32 ========================"
    addGroupChoices --title="Drivers32" --description="Drivers32"  \
                    --enabled="!choices['UEFI.only'].selected"     \
                    "Drivers32"
    packagesidentity="${clover_package_identity}".drivers32
    local drivers=($( find "${SRCROOT}/CloverV2/drivers-Off/drivers32" -type f -name '*.efi' -depth 1 ))
    local driverDestDir='/EFIROOTDIR/EFI/CLOVER/drivers32'
    for (( i = 0 ; i < ${#drivers[@]} ; i++ )); do
        local driver="${drivers[$i]##*/}"
        local driverName="${driver%.efi}"
        ditto --noextattr --noqtn --arch i386 "${drivers[$i]}" "${PKG_BUILD_DIR}/${driverName}/Root/"
        find "${PKG_BUILD_DIR}/${driverName}" -name '.DS_Store' -exec rm -R -f {} \; 2>/dev/null
        fixperms "${PKG_BUILD_DIR}/${driverName}/Root/"

        packageRefId=$(getPackageRefId "${packagesidentity}" "${driverName}")
        addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${driverName}" \
                           --subst="INSTALLER_CHOICE=$packageRefId" MarkChoice
        buildpackage "$packageRefId" "${driverName}" "${PKG_BUILD_DIR}/${driverName}" "${driverDestDir}"
        addChoice --group="Drivers32" --title="$driverName"                                               \
                  --enabled="!choices['UEFI.only'].selected"                                              \
                  --start-selected="choicePreviouslySelected('$packageRefId')"                            \
                  --selected="!choices['UEFI.only'].selected &amp;&amp; choices['$driverName'].selected"  \
                  --pkg-refs="$packageRefId"                                                              \
                  "${driverName}"
        rm -R -f "${PKG_BUILD_DIR}/${driverName}"
    done
# End build drivers-ia32 packages

# build mandatory drivers-ia32UEFI packages
    echo "=============== drivers32 UEFI mandatory ==============="
    packagesidentity="${clover_package_identity}".drivers32UEFI.mandatory
    local drivers=($( find "${SRCROOT}/CloverV2/EFI/CLOVER/drivers32UEFI" -type f -name '*.efi' -depth 1 ))
    local driverDestDir='/EFIROOTDIR/EFI/CLOVER/drivers32UEFI'
    for (( i = 0 ; i < ${#drivers[@]} ; i++ ))
    do
        local driver="${drivers[$i]##*/}"
        local driverChoice="${driver%.efi}.UEFI"
        ditto --noextattr --noqtn --arch i386 "${drivers[$i]}" "${PKG_BUILD_DIR}/${driverChoice}/Root/"
        find "${PKG_BUILD_DIR}/${driverChoice}" -name '.DS_Store' -exec rm -R -f {} \; 2>/dev/null
        fixperms "${PKG_BUILD_DIR}/${driverChoice}/Root/"

        packageRefId=$(getPackageRefId "${packagesidentity}" "${driverChoice}")
        # Add postinstall script for VBoxHfs driver to remove it if HFSPlus driver exists
        [[ "$driver" == VBoxHfs* ]] && \
         addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${driverChoice}"   \
                            --subst="DRIVER_NAME=$driver"                    \
                            --subst="DRIVER_DIR=$(basename $driverDestDir)"  \
                            "VBoxHfs"
        buildpackage "$packageRefId" "${driverChoice}" "${PKG_BUILD_DIR}/${driverChoice}" "${driverDestDir}"
        addChoice --start-visible="false" --start-selected="true" --pkg-refs="$packageRefId"  "${driverChoice}"
        rm -R -f "${PKG_BUILD_DIR}/${driverChoice}"
    done
# End mandatory drivers-ia32UEFI packages
fi

# build mandatory drivers-x64 packages
if [[ -d "${SRCROOT}/CloverV2/EFI/CLOVER/drivers64"  ]]; then
    echo "================= drivers64 mandatory =================="
    packagesidentity="${clover_package_identity}".drivers64.mandatory
    local drivers=($( find "${SRCROOT}/CloverV2/EFI/CLOVER/drivers64" -type f -name '*.efi' -depth 1 ))
    local driverDestDir='/EFIROOTDIR/EFI/CLOVER/drivers64'
    for (( i = 0 ; i < ${#drivers[@]} ; i++ ))
    do
        local driver="${drivers[$i]##*/}"
        local driverChoice="${driver%.efi}"
        ditto --noextattr --noqtn --arch i386 "${drivers[$i]}" "${PKG_BUILD_DIR}/${driverChoice}/Root/"
        find "${PKG_BUILD_DIR}/${driverChoice}" -name '.DS_Store' -exec rm -R -f {} \; 2>/dev/null
        fixperms "${PKG_BUILD_DIR}/${driverChoice}/Root/"

        packageRefId=$(getPackageRefId "${packagesidentity}" "${driverChoice}")
        # Add postinstall script for VBoxHfs driver to remove it if HFSPlus driver exists
        [[ "$driver" == VBoxHfs* ]] && \
         addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${driverChoice}"  \
                            --subst="DRIVER_NAME=$driver"                     \
                            --subst="DRIVER_DIR=$(basename $driverDestDir)"   \
                            "VBoxHfs"
        buildpackage "$packageRefId" "${driverChoice}" "${PKG_BUILD_DIR}/${driverChoice}" "${driverDestDir}"
        addChoice --start-visible="false" --selected="!choices['UEFI.only'].selected"  \
         --pkg-refs="$packageRefId"  "${driverChoice}"
        rm -R -f "${PKG_BUILD_DIR}/${driverChoice}"
    done
fi
# End mandatory drivers-x64 packages

# build drivers-x64 packages
if [[ -d "${SRCROOT}/CloverV2/drivers-Off/drivers64" ]]; then
    echo "===================== drivers64 ========================"
    addGroupChoices --title="Drivers64" --description="Drivers64"  \
                    --enabled="!choices['UEFI.only'].selected"     \
                    "Drivers64"
    packagesidentity="${clover_package_identity}".drivers64
    local drivers=($( find "${SRCROOT}/CloverV2/drivers-Off/drivers64" -type f -name '*.efi' -depth 1 ))
    local driverDestDir='/EFIROOTDIR/EFI/CLOVER/drivers64'
    for (( i = 0 ; i < ${#drivers[@]} ; i++ )); do
        local driver="${drivers[$i]##*/}"
        local driverName="${driver%.efi}"
        ditto --noextattr --noqtn --arch i386 "${drivers[$i]}" "${PKG_BUILD_DIR}/${driverName}/Root/"
        find "${PKG_BUILD_DIR}/${driverName}" -name '.DS_Store' -exec rm -R -f {} \; 2>/dev/null
        fixperms "${PKG_BUILD_DIR}/${driverName}/Root/"

        packageRefId=$(getPackageRefId "${packagesidentity}" "${driverName}")
        addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${driverName}" \
                           --subst="INSTALLER_CHOICE=$packageRefId" MarkChoice
        buildpackage "$packageRefId" "${driverName}" "${PKG_BUILD_DIR}/${driverName}" "${driverDestDir}"
        addChoice --group="Drivers64" --title="$driverName"                                               \
                  --enabled="!choices['UEFI.only'].selected"                                              \
                  --start-selected="choicePreviouslySelected('$packageRefId')"                            \
                  --selected="!choices['UEFI.only'].selected &amp;&amp; choices['$driverName'].selected"  \
                  --pkg-refs="$packageRefId"                                                              \
                  "${driverName}"
        rm -R -f "${PKG_BUILD_DIR}/${driverName}"
    done
fi
# End build drivers-x64 packages

# build mandatory drivers-x64UEFI packages
if [[ -d "${SRCROOT}/CloverV2/EFI/CLOVER/drivers64UEFI" ]]; then
    echo "=============== drivers64 UEFI mandatory ==============="
    packagesidentity="${clover_package_identity}".drivers64UEFI.mandatory
    local drivers=($( find "${SRCROOT}/CloverV2/EFI/CLOVER/drivers64UEFI" -type f -name '*.efi' -depth 1 ))
    local driverDestDir='/EFIROOTDIR/EFI/CLOVER/drivers64UEFI'
    for (( i = 0 ; i < ${#drivers[@]} ; i++ ))
    do
        local driver="${drivers[$i]##*/}"
        local driverChoice="${driver%.efi}.UEFI"
        ditto --noextattr --noqtn --arch i386 "${drivers[$i]}" "${PKG_BUILD_DIR}/${driverChoice}/Root/"
        find "${PKG_BUILD_DIR}/${driverChoice}" -name '.DS_Store' -exec rm -R -f {} \; 2>/dev/null
        fixperms "${PKG_BUILD_DIR}/${driverChoice}/Root/"

        packageRefId=$(getPackageRefId "${packagesidentity}" "${driverChoice}")
        # Add postinstall script for VBoxHfs driver to remove it if HFSPlus driver exists
        [[ "$driver" == VBoxHfs* ]] && \
         addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${driverChoice}"  \
                            --subst="DRIVER_NAME=$driver"                     \
                            --subst="DRIVER_DIR=$(basename $driverDestDir)"   \
                            "VBoxHfs"
        buildpackage "$packageRefId" "${driverChoice}" "${PKG_BUILD_DIR}/${driverChoice}" "${driverDestDir}"
        addChoice --start-visible="false" --start-selected="true" --pkg-refs="$packageRefId"  "${driverChoice}"
        rm -R -f "${PKG_BUILD_DIR}/${driverChoice}"
    done
fi
# End mandatory drivers-x64UEFI packages

# build drivers-x64UEFI packages 
if [[ -d "${SRCROOT}/CloverV2/drivers-Off/drivers64UEFI" ]]; then
    echo "=================== drivers64 UEFI ====================="
    addGroupChoices --title="Drivers64UEFI" --description="Drivers64UEFI" "Drivers64UEFI"
    packagesidentity="${clover_package_identity}".drivers64UEFI
    local drivers=($( find "${SRCROOT}/CloverV2/drivers-Off/drivers64UEFI" -type f -name '*.efi' -depth 1 ))
    local driverDestDir='/EFIROOTDIR/EFI/CLOVER/drivers64UEFI'
    for (( i = 0 ; i < ${#drivers[@]} ; i++ ))
    do
        local driver="${drivers[$i]##*/}"
        local driverName="${driver%.efi}"
        ditto --noextattr --noqtn --arch i386 "${drivers[$i]}" "${PKG_BUILD_DIR}/${driverName}/Root/"
        find "${PKG_BUILD_DIR}/${driverName}" -name '.DS_Store' -exec rm -R -f {} \; 2>/dev/null
        fixperms "${PKG_BUILD_DIR}/${driverName}/Root/"

        packageRefId=$(getPackageRefId "${packagesidentity}" "${driverName}")
        addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${driverName}" \
                           --subst="INSTALLER_CHOICE=$packageRefId" MarkChoice
        buildpackage "$packageRefId" "${driverName}" "${PKG_BUILD_DIR}/${driverName}" "${driverDestDir}"
        addChoice --group="Drivers64UEFI"  --title="$driverName"                \
                  --start-selected="choicePreviouslySelected('$packageRefId')"  \
                  --pkg-refs="$packageRefId"  "${driverName}"
        rm -R -f "${PKG_BUILD_DIR}/${driverName}"
    done
fi
# End build drivers-x64UEFI packages

# build rc scripts package
    echo "===================== RC Scripts ======================="
    packagesidentity="$clover_package_identity"


    choiceId="rc.scripts.on.target"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    rcScriptsOnTargetPkgRefId=$packageRefId
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}" \
                       --subst="INSTALLER_CHOICE=$packageRefId" MarkChoice
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    addChoice --start-visible="true" \
              --start-selected="checkFileExists('/System/Library/CoreServices/boot.efi') &amp;&amp; choicePreviouslySelected('$packageRefId')" \
              --start-enabled="checkFileExists('/System/Library/CoreServices/boot.efi')" \
              --pkg-refs="$packageRefId" "${choiceId}"

    choiceId="rc.scripts.on.all.volumes"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    rcScriptsOnAllColumesPkgRefId=$packageRefId
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}" \
                       --subst="INSTALLER_CHOICE=$packageRefId" MarkChoice
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    addChoice --start-visible="true" --start-selected="choicePreviouslySelected('$packageRefId')" \
              --pkg-refs="$packageRefId" "${choiceId}"

    choiceIdRcScriptsCore="rc.scripts.core"
    choiceId=$choiceIdRcScriptsCore
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root/Library/LaunchDaemons
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root/Library/Application\ Support/Clover
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root/etc
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Scripts
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}"                            \
                       --subst="INSTALLER_ON_TARGET_REFID=$rcScriptsOnTargetPkgRefId"          \
                       --subst="INSTALLER_ON_ALL_VOLUMES_REFID=$rcScriptsOnAllColumesPkgRefId" \
                       RcScripts
    # Add the rc script library
    cp -f "$SCPT_LIB_DIR"/rc_scripts.lib "${PKG_BUILD_DIR}/${choiceId}"/Scripts
    rsync -r --exclude=.* --exclude="*~" ${SRCROOT}/CloverV2/rcScripts/ ${PKG_BUILD_DIR}/${choiceId}/Root/
    local toolsdir="${PKG_BUILD_DIR}/${choiceId}"/Scripts/Tools
    mkdir -p "$toolsdir"
    (cd "${PKG_BUILD_DIR}/${choiceId}"/Root && find {etc,Library} -type f > "$toolsdir"/rc.files)
    fixperms "${PKG_BUILD_DIR}/${choiceId}/Root/"
    chmod 644 "${PKG_BUILD_DIR}/${choiceId}/Root/Library/LaunchDaemons/com.projectosx.clover.daemon.plist"
    chmod 744 "${PKG_BUILD_DIR}/${choiceId}/Root/Library/Application Support/Clover/CloverDaemon"
    chmod 755 "${PKG_BUILD_DIR}/${choiceId}/Root/etc"/rc.*.d/*.{local,local.disabled}
    chmod 755 "${PKG_BUILD_DIR}/${choiceId}/Scripts/postinstall"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    addChoice --start-visible="false" \
              --selected="choices['rc.scripts.on.target'].selected || choices['rc.scripts.on.all.volumes'].selected" \
              --pkg-refs="$packageRefId" "${choiceId}"
# End build rc scripts package

# build optional rc scripts package
    echo "================= Optional RC Scripts =================="
    packagesidentity="$clover_package_identity".optional.rc.scripts
    addGroupChoices --title="Optional RC Scripts" --description="Optional RC Scripts" \
                    --enabled="choices['$choiceIdRcScriptsCore'].selected"            \
                    "OptionalRCScripts"
    local scripts=($( find "${SRCROOT}/CloverV2/rcScripts/etc" -type f -name '*.disabled' -depth 2 ))
    for (( i = 0 ; i < ${#scripts[@]} ; i++ ))
    do
        local script_rel_path=etc/"${scripts[$i]##*/etc/}" # ie: etc/rc.boot.d/70.xx_yy_zz.local.disabled
        local script="${script_rel_path##*/}" # ie: 70.xx_yy_zz.local.disabled
        local choiceId=$(echo "$script" | sed -E 's/^[0-9]*[.]?//;s/\.local\.disabled//') # ie: xx_yy_zz
        local title=${choiceId//_/ } # ie: xx yy zz
        packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
        mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
        addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}"                           \
                          --subst="RC_SCRIPT=$script_rel_path"                                    \
                          --subst="INSTALLER_ON_TARGET_REFID=$rcScriptsOnTargetPkgRefId"          \
                          --subst="INSTALLER_ON_ALL_VOLUMES_REFID=$rcScriptsOnAllColumesPkgRefId" \
                          --subst="INSTALLER_CHOICE=$packageRefId"                                \
                          OptRcScripts
        # Add the rc script library
        cp -f "$SCPT_LIB_DIR"/rc_scripts.lib "${PKG_BUILD_DIR}/${choiceId}"/Scripts
        fixperms  "${PKG_BUILD_DIR}/${choiceId}/Root/"
        chmod 755 "${PKG_BUILD_DIR}/${choiceId}/Scripts/postinstall"
        buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
        addChoice --group="OptionalRCScripts" --title="$title"                  \
                  --start-selected="choicePreviouslySelected('$packageRefId')"  \
                  --enabled="choices['OptionalRCScripts'].enabled"              \
                  --pkg-refs="$packageRefId" "${choiceId}"
    done
# End build optional rc scripts package

local cloverUpdaterDir="${SRCROOT}"/CloverUpdater
local cloverPrefpaneDir="${SRCROOT}"/CloverPrefpane
if [[ -x "$cloverPrefpaneDir"/build/Clover.prefPane/Contents/MacOS/Clover ]]; then
# build CloverPrefpane package
    echo "==================== Clover Prefpane ==================="
    packagesidentity="$clover_package_identity"
    choiceId="CloverPrefpane"
    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    # ditto --noextattr --noqtn "$cloverUpdaterDir"/CloverUpdaterUtility.plist  \
    #  "${PKG_BUILD_DIR}/${choiceId}"/Root/Library/LaunchAgents/com.projectosx.Clover.Updater.plist
    ditto --noextattr --noqtn "$cloverUpdaterDir"/CloverUpdaterUtility  \
     "${PKG_BUILD_DIR}/${choiceId}/Root/Library/Application Support/Clover"/
    ditto --noextattr --noqtn "$cloverUpdaterDir"/build/CloverUpdater.app  \
     "${PKG_BUILD_DIR}/${choiceId}/Root/Library/Application Support/Clover"/CloverUpdater.app
    ditto --noextattr --noqtn "$cloverPrefpaneDir"/build/Clover.prefPane  \
     "${PKG_BUILD_DIR}/${choiceId}/Root/Library/PreferencePanes/"/Clover.prefPane
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}" \
                       --subst="INSTALLER_CHOICE=$packageRefId" MarkChoice
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    addChoice --start-selected="checkFileExists('/bin/launchctl') &amp;&amp; choicePreviouslySelected('$packageRefId')" \
              --start-enabled="checkFileExists('/bin/launchctl')"                                                       \
              --pkg-refs="$packageRefId" "${choiceId}"
# end CloverUpdater package
fi

# build post install package
    echo "================= Post ================="
    packagesidentity="${clover_package_identity}"
    choiceId="Post"
    mkdir -p ${PKG_BUILD_DIR}/${choiceId}/Root
    addTemplateScripts --pkg-rootdir="${PKG_BUILD_DIR}/${choiceId}" ${choiceId}
    # cp -f ${PKGROOT}/Scripts/Sub/UnMountEFIvolumes.sh ${PKG_BUILD_DIR}/${choiceId}/Scripts

    packageRefId=$(getPackageRefId "${packagesidentity}" "${choiceId}")
    buildpackage "$packageRefId" "${choiceId}" "${PKG_BUILD_DIR}/${choiceId}" "/"
    addChoice  --start-visible="false" --start-selected="true"  --pkg-refs="$packageRefId" "${choiceId}"
# End build post install package

}

fixperms ()
{
    # $1 path
    find "${1}" -type f -exec chmod 644 {} \;
    find "${1}" -type d -exec chmod 755 {} \;
}

buildoptionalsettings()
{
    # $1 Path to package to build containing Root and or Scripts
    # $2 = exclusiveFlag
    # S3 = exclusiveName

    # ------------------------------------------------------
    # if exclusiveFlag=1 then re-build array
    # adding extra boot option at beginning to give
    # user a chance to choose none of them.
    # ------------------------------------------------------
    if [ ${2} = "1" ]; then
        tempArray=("${availableOptions[@]}")
        availableOptions=()
        availableOptions[0]="ChooseNone-"$3":DONT=ADD"
        position=0
        totalItems="${#tempArray[@]}"
        for (( position = 0 ; position < $totalItems ; position++ ))
        do
            availableOptions[$position+1]=${tempArray[${position}]}
        done
    fi

    # ------------------------------------------------------
    # Loop through options in array and process each in turn
    # ------------------------------------------------------
    for (( c = 0 ; c < ${#availableOptions[@]} ; c++ ))
    do
        textLine=${availableOptions[c]}
        # split line - taking all before ':' as option name
        # and all after ':' as key/value
        optionName=${textLine%:*}
        keyValue=${textLine##*:}

        # create folders required for each boot option
        mkdir -p "${1}/$optionName/Root/"

        # create dummy file with name of key/value
        echo "" > "${1}/$optionName/Root/${keyValue}"

        echo "  [BUILD] ${optionName} "

        # ------------------------------------------------------
        # Before calling buildpackage, add exclusive options
        # to buildpackage call if requested.
        # ------------------------------------------------------
        if [ $2 = "1" ]; then

            # Prepare individual string parts
            stringStart="selected=\""
            stringBefore="exclusive(choices['"
            stringAfter="']) &amp;&amp; "
            stringEnd="'])\""
            x=${stringStart}${stringBefore}

            # build string for sending to buildpackage
            totalItems="${#availableOptions[@]}"
            lastItem=$((totalItems-1))

            for (( r = 0 ; r < ${totalItems} ; r++ ))
            do
                textLineTemp=${availableOptions[r]}
                optionNameTemp=${textLineTemp%:*}
                if [ "${optionNameTemp}" != "${optionName}" ]; then
                     x="${x}${optionNameTemp}"
                     # Only add these to end of string up to the one before the last item
                    if [ $r -lt $lastItem ]; then
                        x="${x}${stringAfter}${stringBefore}"
                    fi
                fi
            done
            x="${x}${stringEnd}"

            # First exclusive option is the 'no choice' option, so let's make that selected by default.
            if [ $c = 0 ]; then
                initialChoice="true"
            else
                initialChoice="false"
            fi

            buildpackage "${1}/${optionName}" "/tmpcham/chamTemp/options" "" "start_selected=\"${initialChoice}\" ${x}" >/dev/null 2>&1
        else
            buildpackage "${1}/${optionName}" "/tmpcham/chamTemp/options" "" "start_selected=\"false\"" >/dev/null 2>&1
        fi
    done
}

buildpackage ()
{
    #  $1 Package Reference Id (ie: org.clover.themes.default)
    #  $2 Package Name (ie: Default)
    #  $3 Path to package to build containing Root and/or Scripts
    #  $4 Target install location
    #  $5 Size (optional)
    if [[ -d "${3}/Root" ]]; then
        local packageRefId="$1"
        local packageName="$2"
        local packagePath="$3"
        local targetPath="$4"
        set +u # packageSize is optional
        local packageSize="$5"
        set -u

        echo -e "\t[BUILD] ${packageName}"

        find "${packagePath}" \( -name '.DS_Store' -o -name '.svn' \) -print0 | xargs -0 rm -rf
        local filecount=$( find "${packagePath}/Root" | wc -l )
        if [ "${packageSize}" ]; then
            local installedsize="${packageSize}"
        else
            local installedsize=$( du -hkc "${packagePath}/Root" | tail -n1 | awk {'print $1'} )
        fi
        local header="<?xml version=\"1.0\"?>\n<pkg-info format-version=\"2\" "

        #[ "${3}" == "relocatable" ] && header+="relocatable=\"true\" "

        header+="identifier=\"${packageRefId}\" "
        header+="version=\"${CLOVER_VERSION}\" "

        [ "${targetPath}" != "relocatable" ] && header+="install-location=\"${targetPath}\" "

        header+="auth=\"root\">\n"
        header+="\t<payload installKBytes=\"${installedsize##* }\" numberOfFiles=\"${filecount##* }\"/>\n"
        rm -R -f "${packagePath}/Temp"

        [ -d "${packagePath}/Temp" ] || mkdir -m 777 "${packagePath}/Temp"
        [ -d "${packagePath}/Root" ] && mkbom "${packagePath}/Root" "${packagePath}/Temp/Bom"

        if [ -d "${packagePath}/Scripts" ]; then
            header+="\t<scripts>\n"
            for script in $( find "${packagePath}/Scripts" -type f \( -name 'pre*' -or -name 'post*' \) ); do
                header+="\t\t<${script##*/} file=\"./${script##*/}\"/>\n"
            done
            header+="\t</scripts>\n"
            # Create the Script archive file (cpio format)
            (cd "${packagePath}/Scripts" && find . -print |                                    \
                cpio -o -z -R root:wheel --format cpio > "${packagePath}/Temp/Scripts") 2>&1 | \
                grep -vE '^[0-9]+\s+blocks?$' # to remove cpio stderr messages
        fi

        header+="</pkg-info>"
        echo -e "${header}" > "${packagePath}/Temp/PackageInfo"

        # Create the Payload file (cpio format)
        (cd "${packagePath}/Root" && find . -print |                                       \
            cpio -o -z -R root:wheel --format cpio > "${packagePath}/Temp/Payload") 2>&1 | \
            grep -vE '^[0-9]+\s+blocks?$' # to remove cpio stderr messages

        # Create the package
        (cd "${packagePath}/Temp" && xar -c -f "${packagePath}/../${packageName}.pkg" --compression none .)

        # Add the package to the list of build packages
        pkgrefs[${#pkgrefs[*]}]="\t<pkg-ref id=\"${packageRefId}\" installKBytes='${installedsize}' version='${CLOVER_VERSION}.0.0.${CLOVER_TIMESTAMP}'>#${packageName}.pkg</pkg-ref>"

        rm -rf "${packagePath}"
    fi
}

generateOutlineChoices() {
    # $1 Main Choice
    # $2 indent level
    local idx=$(getChoiceIndex "$1")
    local indentLevel="$2"
    local indentString=""
    for ((level=1; level <= $indentLevel ; level++)); do
        indentString="\t$indentString"
    done
    set +u; subChoices="${choice_group_items[$idx]}"; set -u
    if [[ -n "${subChoices}" ]]; then
        # Sub choices exists
        echo -e "$indentString<line choice=\"$1\">"
        for subChoice in $subChoices;do
            generateOutlineChoices $subChoice $(($indentLevel+1))
        done
        echo -e "$indentString</line>"
    else
        echo -e "$indentString<line choice=\"$1\"/>"
    fi
}

generateChoices() {
    for (( idx=1; idx < ${#choice_key[*]} ; idx++)); do
        local choiceId=${choice_key[$idx]}
        local choiceTitle=${choice_title[$idx]}
        local choiceDescription=${choice_description[$idx]}
        local choiceOptions=${choice_options[$idx]}
        local choiceParentGroupIndex=${choice_parent_group_index[$idx]}
        set +u; local group_exclusive=${choice_group_exclusive[$choiceParentGroupIndex]}; set -u
        local selected_option="${choice_selected[$idx]}"
        local exclusive_option=""

        # Create the node and standard attributes
        local choiceNode="\t<choice\n\t\tid=\"${choiceId}\"\n\t\ttitle=\"${choiceTitle}\"\n\t\tdescription=\"${choiceDescription}\""

        # Add options like start_selected, etc...
        [[ -n "${choiceOptions}" ]] && choiceNode="${choiceNode}\n\t\t${choiceOptions}"

        # Add the selected attribute if options are mutually exclusive
        if [[ -n "$group_exclusive" ]];then
            local group_items="${choice_group_items[$choiceParentGroupIndex]}"
            case $group_exclusive in
                exclusive_one_choice)
                    local exclusive_option=$(exclusive_one_choice "$choiceId" "$group_items")
                    if [[ -n "$selected_option" ]]; then
                        selected_option="($selected_option) &amp;&amp; $exclusive_option"
                    else
                        selected_option="$exclusive_option"
                    fi
                    ;;
                exclusive_zero_or_one_choice)
                    local exclusive_option=$(exclusive_zero_or_one_choice "$choiceId" "$group_items")
                    if [[ -n "$selected_option" ]]; then
                        selected_option="($selected_option) &amp;&amp; $exclusive_option"
                    else
                        selected_option="$exclusive_option"
                    fi
                    ;;
                *) echo "Error: unknown function to generate exclusive mode '$group_exclusive' for group '${choice_key[$choiceParentGroupIndex]}'" >&2
                   exit 1
                   ;;
            esac
        fi

        if [[ -n "${choice_force_selected[$idx]}" ]]; then
            if [[ -n "$selected_option" ]]; then
                selected_option="(${choice_force_selected[$idx]}) || $selected_option"
            else
                selected_option="${choice_force_selected[$idx]}"
            fi
        fi

        [[ -n "$selected_option" ]] && choiceNode="${choiceNode}\n\t\tselected=\"$selected_option\""

        choiceNode="${choiceNode}>"

        # Add the package references
        for pkgRefId in ${choice_pkgrefs[$idx]};do
            choiceNode="${choiceNode}\n\t\t<pkg-ref id=\"${pkgRefId}\"/>"
        done

        # Close the node
        choiceNode="${choiceNode}\n\t</choice>\n"

        echo -e "$choiceNode"
    done
}

makedistribution ()
{
    declare -r distributionDestDir="${SYMROOT}"
    declare -r distributionFilename="${packagename// /}_${CLOVER_VERSION}_r${CLOVER_REVISION}.pkg"
    declare -r distributionFilePath="${distributionDestDir}/${distributionFilename}"

    rm -f "${distributionDestDir}/${packagename// /}"*.pkg

    mkdir -p "${PKG_BUILD_DIR}/${packagename}"

    find "${PKG_BUILD_DIR}" -type f -name '*.pkg' -depth 1 | while read component
    do
        pkg="${component##*/}" # ie: EFI.pkg
        pkgdir="${PKG_BUILD_DIR}/${packagename}/${pkg}"
        # expand individual packages
        pkgutil --expand "${PKG_BUILD_DIR}/${pkg}" "$pkgdir"
        rm -f "${PKG_BUILD_DIR}/${pkg}"
    done

    # Create the Distribution file
    ditto --noextattr --noqtn "${PKGROOT}/Distribution" "${PKG_BUILD_DIR}/${packagename}/Distribution"
    makeSubstitutions "${PKG_BUILD_DIR}/${packagename}/Distribution"

    local start_indent_level=2
    echo -e "\n\t<choices-outline>" >> "${PKG_BUILD_DIR}/${packagename}/Distribution"
    for main_choice in ${choice_group_items[0]};do
        generateOutlineChoices $main_choice $start_indent_level >> "${PKG_BUILD_DIR}/${packagename}/Distribution"
    done
    echo -e "\t</choices-outline>\n" >> "${PKG_BUILD_DIR}/${packagename}/Distribution"

    generateChoices >> "${PKG_BUILD_DIR}/${packagename}/Distribution"

    for (( i=0; i < ${#pkgrefs[*]} ; i++)); do
        echo -e "${pkgrefs[$i]}" >> "${PKG_BUILD_DIR}/${packagename}/Distribution"
    done

    echo -e "\n</installer-gui-script>"  >> "${PKG_BUILD_DIR}/${packagename}/Distribution"

    # Create the Resources directory
    ditto --noextattr --noqtn "${PKGROOT}/Resources/background.tiff" "${PKG_BUILD_DIR}/${packagename}"/Resources/
    ditto --noextattr --noqtn "${SYMROOT}/Resources/${packagename}"/ "${PKG_BUILD_DIR}/${packagename}"/

    # CleanUp the directory
    find "${PKG_BUILD_DIR}/${packagename}" \( -type d -name '.svn' \) -o -name '.DS_Store' -depth -exec rm -rf {} \;
    find "${PKG_BUILD_DIR}/${packagename}" -type d -depth -empty -exec rmdir {} \; # Remove empty directories

    # Make substitutions for version, revision, stage, developers, credits, etc..
    makeSubstitutions $( find "${PKG_BUILD_DIR}/${packagename}/Resources" -type f )

    # Create the final package
    pkgutil --flatten "${PKG_BUILD_DIR}/${packagename}" "${distributionFilePath}"

    #   Here is the place to assign an icon to the pkg
    #   Icon pkg reworked by ErmaC
    ditto -xk "${PKGROOT}/Icon.zip" "${PKG_BUILD_DIR}/Icons/"
    DeRez -only icns "${PKG_BUILD_DIR}/Icons/Icon.icns" > "${PKG_BUILD_DIR}/Icons/tempicns.rsrc"
    Rez -append "${PKG_BUILD_DIR}/Icons/tempicns.rsrc" -o "${distributionFilePath}"
    SetFile -a C "${distributionFilePath}"
    rm -rf "${PKG_BUILD_DIR}/Icons"

    md5=$( md5 "${distributionFilePath}" | awk {'print $4'} )
    echo "MD5 (${distributionFilePath}) = ${md5}" > "${distributionFilePath}.md5"
    echo ""

    echo -e $COL_GREEN" --------------------------"$COL_RESET
    echo -e $COL_GREEN" Building process complete!"$COL_RESET
    echo -e $COL_GREEN" --------------------------"$COL_RESET
    echo ""
    echo -e $COL_GREEN" Build info."
    echo -e $COL_GREEN" ==========="
    echo -e $COL_BLUE"  Package name: "$COL_RESET"${distributionFilename}"
    echo -e $COL_BLUE"  MD5:          "$COL_RESET"$md5"
    echo -e $COL_BLUE"  Version:      "$COL_RESET"$CLOVER_VERSION"
    echo -e $COL_BLUE"  Stage:        "$COL_RESET"$CLOVER_STAGE"
    echo -e $COL_BLUE"  Date/Time:    "$COL_RESET"$CLOVER_BUILDDATE"
    echo -e $COL_BLUE"  Built by:     "$COL_RESET"$CLOVER_WHOBUILD"
    echo -e $COL_BLUE"  Copyright     "$COL_RESET"$CLOVER_CPRYEAR"
    echo ""
}

# build packages
main

# build meta package
makedistribution


# Local Variables:      #
# mode: ksh             #
# tab-width: 4          #
# indent-tabs-mode: nil #
# End:                  #
#
# vi: set expandtab ts=4 sw=4 sts=4: #
