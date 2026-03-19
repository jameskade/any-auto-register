"""平台操作 API - 通用接口，各平台通过 get_platform_actions/execute_action 实现"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlmodel import Session, select

from core.base_platform import RegisterConfig
from core.db import AccountModel, get_session
from core.registry import get

router = APIRouter(prefix="/actions", tags=["actions"])


class ActionRequest(BaseModel):
    params: dict = {}


class BulkActionRequest(BaseModel):
    account_ids: list[int]
    params: dict = {}


def _build_account(acc_model: AccountModel):
    from core.base_platform import Account, AccountStatus

    return Account(
        platform=acc_model.platform,
        email=acc_model.email,
        password=acc_model.password,
        user_id=acc_model.user_id,
        token=acc_model.token,
        status=AccountStatus(acc_model.status),
        extra=acc_model.get_extra(),
    )


def _apply_result_updates(acc_model: AccountModel, result: dict, session: Session) -> None:
    # 动作返回新的 token/字段时，统一回写数据库，避免批量与单个逻辑分叉。
    if not result.get("ok") or not isinstance(result.get("data"), dict):
        return

    data = result["data"]
    if "access_token" not in data:
        return

    extra = acc_model.get_extra()
    extra.update(data)
    acc_model.set_extra(extra)
    if data.get("access_token"):
        acc_model.token = data["access_token"]

    from datetime import datetime

    acc_model.updated_at = datetime.utcnow()
    session.add(acc_model)
    session.commit()


def _execute_action_for_model(platform: str, action_id: str, params: dict, acc_model: AccountModel, session: Session) -> dict:
    PlatformCls = get(platform)
    instance = PlatformCls(config=RegisterConfig())
    account = _build_account(acc_model)
    result = instance.execute_action(action_id, account, params)
    _apply_result_updates(acc_model, result, session)
    return result


@router.get("/{platform}")
def list_actions(platform: str):
    """获取平台支持的操作列表"""
    PlatformCls = get(platform)
    instance = PlatformCls(config=RegisterConfig())
    return {"actions": instance.get_platform_actions()}


@router.post("/{platform}/{account_id}/{action_id}")
def execute_action(
    platform: str,
    account_id: int,
    action_id: str,
    body: ActionRequest,
    session: Session = Depends(get_session),
):
    """执行平台特定操作"""
    acc_model = session.get(AccountModel, account_id)
    if not acc_model or acc_model.platform != platform:
        raise HTTPException(404, "账号不存在")

    try:
        return _execute_action_for_model(platform, action_id, body.params, acc_model, session)
    except NotImplementedError as e:
        raise HTTPException(400, str(e))
    except Exception as e:
        return {"ok": False, "error": str(e)}


@router.post("/{platform}/bulk/{action_id}/run")
def execute_bulk_action(
    platform: str,
    action_id: str,
    body: BulkActionRequest,
    session: Session = Depends(get_session),
):
    """批量执行平台动作，当前主要用于账号列表页的批量上传/处理。"""
    if not body.account_ids:
        raise HTTPException(400, "请选择至少一个账号")

    ids = list(dict.fromkeys(body.account_ids))
    account_models = session.exec(
        select(AccountModel).where(AccountModel.id.in_(ids))
    ).all()
    account_map = {
        acc.id: acc for acc in account_models
        if acc.id is not None and acc.platform == platform
    }

    details = []
    success_count = 0
    failed_count = 0

    for account_id in ids:
        acc_model = account_map.get(account_id)
        if not acc_model:
            failed_count += 1
            details.append({
                "id": account_id,
                "email": None,
                "success": False,
                "error": "账号不存在或平台不匹配",
            })
            continue

        try:
            result = _execute_action_for_model(platform, action_id, body.params, acc_model, session)
            if result.get("ok"):
                success_count += 1
                details.append({
                    "id": account_id,
                    "email": acc_model.email,
                    "success": True,
                    "data": result.get("data"),
                })
            else:
                failed_count += 1
                details.append({
                    "id": account_id,
                    "email": acc_model.email,
                    "success": False,
                    "error": result.get("error") or "操作失败",
                })
        except NotImplementedError as e:
            raise HTTPException(400, str(e))
        except Exception as e:
            failed_count += 1
            details.append({
                "id": account_id,
                "email": acc_model.email,
                "success": False,
                "error": str(e),
            })

    return {
        "ok": failed_count == 0,
        "success_count": success_count,
        "failed_count": failed_count,
        "details": details,
    }
