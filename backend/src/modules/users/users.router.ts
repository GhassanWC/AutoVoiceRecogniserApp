import { Router } from 'express';
import { z } from 'zod';
import { requireAuth } from '../../middleware/auth';
import { getStore } from '../../storage';
import { toPublicUser } from '../auth/auth.service';

export const usersRouter = Router();

usersRouter.use(requireAuth);

usersRouter.get('/profile', async (req, res, next) => {
  try {
    const user = await getStore().getUserById(req.userId!);
    if (!user) {
      res.status(404).json({ error: 'User not found' });
      return;
    }
    res.json({ user: toPublicUser(user) });
  } catch (error) {
    next(error);
  }
});

const preferencesSchema = z
  .object({
    preferredLanguage: z.string().min(2).max(8),
    showOriginalText: z.boolean(),
    autoSpeak: z.boolean(),
    saveHistory: z.boolean(),
    name: z.string().min(1).max(100),
  })
  .partial();

usersRouter.patch('/preferences', async (req, res, next) => {
  try {
    const patch = preferencesSchema.parse(req.body);
    const user = await getStore().updateUserPreferences(req.userId!, patch);
    if (!user) {
      res.status(404).json({ error: 'User not found' });
      return;
    }
    res.json({ user: toPublicUser(user) });
  } catch (error) {
    next(error);
  }
});
